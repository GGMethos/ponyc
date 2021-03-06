use "collections"

actor TCPConnection
  """
  A TCP connection. When connecting, the Happy Eyeballs algorithm is used.
  """
  var _listen: (TCPListener | None) = None
  var _notify: TCPConnectionNotify
  var _connect_count: U64
  var _fd: U64 = -1
  var _event: EventID = Event.none()
  var _connected: Bool = false
  var _readable: Bool = false
  var _writeable: Bool = false
  var _closed: Bool = false
  var _shutdown: Bool = false
  var _shutdown_peer: Bool = false
  let _pending: List[(Bytes, U64)] = _pending.create()
  var _read_buf: Array[U8] iso = recover Array[U8].undefined(64) end

  new create(notify: TCPConnectionNotify iso, host: String, service: String,
    from: String = "")
  =>
    """
    Connect via IPv4 or IPv6. If `from` is a non-empty string, the connection
    will be made from the specified interface.
    """
    _notify = consume notify
    _connect_count = @os_connect_tcp[U64](this, host.cstring(),
      service.cstring(), from.cstring())
    _notify_connecting()

  new ip4(notify: TCPConnectionNotify iso, host: String, service: String,
    from: String = "")
  =>
    """
    Connect via IPv4.
    """
    _notify = consume notify
    _connect_count = @os_connect_tcp4[U64](this, host.cstring(),
      service.cstring(), from.cstring())
    _notify_connecting()

  new ip6(notify: TCPConnectionNotify iso, host: String, service: String,
    from: String = "")
  =>
    """
    Connect via IPv6.
    """
    _notify = consume notify
    _connect_count = @os_connect_tcp6[U64](this, host.cstring(),
      service.cstring(), from.cstring())
    _notify_connecting()

  new _accept(listen: TCPListener, notify: TCPConnectionNotify iso, fd: U64) =>
    """
    A new connection accepted on a server.
    """
    _listen = listen
    _notify = consume notify
    _connect_count = 0
    _fd = fd
    _event = @asio_event_create[Pointer[Event]](this, fd, U32(3), true)
    _connected = true

    _queue_read()
    _notify.accepted(this)

  be write(data: Bytes) =>
    """
    Write a single sequence of bytes.
    """
    if not _closed then
      try
        write_final(_notify.sent(this, data))
      end
    end

  be writev(data: BytesList) =>
    """
    Write a sequence of sequences of bytes.
    """
    if not _closed then
      for bytes in data.values() do
        try
          write_final(_notify.sent(this, bytes))
        end
      end
    end

  be set_notify(notify: TCPConnectionNotify iso) =>
    """
    Change the notifier.
    """
    _notify = consume notify

  be dispose() =>
    """
    Close the connection gracefully once all writes are sent.
    """
    close()

  fun local_address(): IPAddress =>
    """
    Return the local IP address.
    """
    let ip = recover IPAddress end
    @os_sockname[Bool](_fd, ip)
    ip

  fun remote_address(): IPAddress =>
    """
    Return the remote IP address.
    """
    let ip = recover IPAddress end
    @os_peername[Bool](_fd, ip)
    ip

  fun ref set_nodelay(state: Bool) =>
    """
    Turn Nagle on/off. Defaults to on. This can only be set on a connected
    socket.
    """
    if _connected then
      @os_nodelay[None](_fd, state)
    end

  fun ref set_keepalive(secs: U32) =>
    """
    Sets the TCP keepalive timeout to approximately secs seconds. Exact timing
    is OS dependent. If secs is zero, TCP keepalive is disabled. TCP keepalive
    is disabled by default. This can only be set on a connected socket.
    """
    if _connected then
      @os_keepalive[None](_fd, secs)
    end

  be _event_notify(event: EventID, flags: U32, arg: U64) =>
    """
    Handle socket events.
    """
    if event isnt _event then
      if Event.writeable(flags) then
        // A connection has completed.
        var fd = @asio_event_data[U64](event)
        _connect_count = _connect_count - 1

        if not _connected and not _closed then
          // We don't have a connection yet.
          if @os_connected[Bool](fd) then
            // The connection was successful, make it ours.
            _fd = fd
            _event = event
            _connected = true

            _queue_read()
            _notify.connected(this)

            // Don't call _complete_writes, as Windows will see this as a
            // closed connection.
            _writeable = true
            _pending_writes()
          else
            // The connection failed, unsubscribe the event and close.
            @asio_event_unsubscribe[None](event)
            @os_closesocket[None](fd)
            _notify_connecting()
          end
        else
          // We're already connected, unsubscribe the event and close.
          @asio_event_unsubscribe[None](event)
          @os_closesocket[None](fd)
        end
      else
        // It's not our event.
        if Event.disposable(flags) then
          // It's disposable, so dispose of it.
          @asio_event_destroy[None](event)
        end
      end
    else
      // At this point, it's our event.
      if Event.writeable(flags) then
        _writeable = true
        _complete_writes(arg)
        _pending_writes()
      end

      if Event.readable(flags) then
        _readable = true
        _complete_reads(arg)
        _pending_reads()
      end

      if Event.disposable(flags) then
        @asio_event_destroy[None](event)
        _event = Event.none()
      end

      _try_shutdown()
    end

  be _read_again() =>
    """
    Resume reading.
    """
    _pending_reads()

  fun ref write_final(data: Bytes) =>
    """
    Write as much as possible to the socket. Set _writeable to false if not
    everything was written. On an error, close the connection. This is for
    data that has already been transformed by the notifier.
    """
    if not _closed then
      if Platform.windows() then
        try
          // Add an IOCP write.
          @os_send[U64](_event, data.cstring(), data.size()) ?
          _pending.push((data, 0))
        end
      else
        if _writeable then
          try
            // Send as much data as possible.
            var len = @os_send[U64](_event, data.cstring(), data.size()) ?

            if len < data.size() then
              // Send any remaining data later.
              _pending.push((data, len))
              _writeable = false
            end
          else
            // Non-graceful shutdown on error.
            _hard_close()
          end
        else
          // Send later, when the socket is available for writing.
          _pending.push((data, 0))
        end
      end
    end

  fun ref _complete_writes(len: U64) =>
    """
    The OS has informed as that len bytes of pending writes have completed.
    This occurs only with IOCP on Windows.
    """
    if Platform.windows() then
      var rem = len

      if rem == 0 then
        // IOCP reported a failed write on this chunk. Non-graceful shutdown.
        try _pending.shift() end
        _hard_close()
        return
      end

      while rem > 0 do
        try
          let node = _pending.head()
          (let data, let offset) = node()
          let total = rem + offset

          if total < data.size() then
            node() = (data, total)
            rem = 0
          else
            _pending.shift()
            rem = total - data.size()
          end
        end
      end
    end

  fun ref _pending_writes() =>
    """
    Send pending data. If any data can't be sent, keep it and mark as not
    writeable. On an error, dispose of the connection.
    """
    if not Platform.windows() then
      while _writeable and (_pending.size() > 0) do
        try
          let node = _pending.head()
          (let data, let offset) = node()

          // Write as much data as possible.
          let len = @os_send[U64](_event, data.cstring().u64() + offset,
            data.size() - offset) ?

          if (len + offset) < data.size() then
            // Send remaining data later.
            node() = (data, offset + len)
            _writeable = false
          else
            // This chunk has been fully sent.
            _pending.shift()
          end
        else
          // Non-graceful shutdown on error.
          _hard_close()
        end
      end
    end

  fun ref _complete_reads(len: U64) =>
    """
    The OS has informed as that len bytes of pending reads have completed.
    This occurs only with IOCP on Windows.
    """
    if Platform.windows() then
      var next = _read_buf.space()

      match len
      | 0 =>
        // The socket has been closed from the other side, or a hard close has
        // cancelled the queued read.
        _readable = false
        _shutdown_peer = true
        close()
        return
      | _read_buf.space() =>
        next = next * 2
      end

      let data = _read_buf = recover Array[U8].undefined(next) end
      data.truncate(len)

      _queue_read()
      _notify.received(this, consume data)
    end

  fun ref _queue_read() =>
    """
    Queue an IOCP read on Windows.
    """
    if Platform.windows() then
      try
        @os_recv[U64](_event, _read_buf.cstring(), _read_buf.space()) ?
      else
        _hard_close()
      end
    end

  fun ref _pending_reads() =>
    """
    Read while data is available, guessing the next packet length as we go. If
    we read 4 kb of data, send ourself a resume message and stop reading, to
    avoid starving other actors.
    """
    if not Platform.windows() then
      try
        var sum: U64 = 0

        while _readable and not _shutdown_peer do
          // Read as much data as possible.
          let len =
            @os_recv[U64](_event, _read_buf.cstring(), _read_buf.space()) ?

          var next = _read_buf.space()

          match len
          | 0 =>
            // Would block, try again later.
            _readable = false
            return
          | _read_buf.space() =>
            // Increase the read buffer size.
            next = next * 2
          end

          let data = _read_buf = recover Array[U8].undefined(next) end
          data.truncate(len)
          _notify.received(this, consume data)

          sum = sum + len

          if sum > (1 << 12) then
            // If we've read 4 kb, yield and read again later.
            _read_again()
            return
          end
        end
      else
        // The socket has been closed from the other side.
        _shutdown_peer = true
        close()
      end
    end

  fun ref _notify_connecting() =>
    """
    Inform the notifier that we're connecting.
    """
    if _connect_count > 0 then
      _notify.connecting(this, _connect_count)
    else
      _notify.connect_failed(this)
      _hard_close()
    end

  fun ref close() =>
    """
    Perform a graceful shutdown. Don't accept new writes, but don't finish
    closing until we get a zero length read.
    """
    _closed = true
    _try_shutdown()

  fun ref _try_shutdown() =>
    """
    If we have closed and we have no remaining writes or pending connections,
    then shutdown.
    """
    if not _closed then
      return
    end

    if
      not _shutdown and
      (_connect_count == 0) and
      (_pending.size() == 0)
    then
      _shutdown = true

      if _connected then
        @os_shutdown[None](_fd)
      else
        _shutdown_peer = true
      end
    end

    if _connected and _shutdown and _shutdown_peer then
      _hard_close()
    end

    if Platform.windows() then
      // On windows, wait until all outstanding IOCP operations have completed
      // or been cancelled.
      if not _connected and not _readable and (_pending.size() == 0) then
        @asio_event_unsubscribe[None](_event)
      end
    end

  fun ref _hard_close() =>
    """
    When an error happens, do a non-graceful close.
    """
    if not _connected then
      return
    end

    _connected = false
    _closed = true
    _shutdown = true
    _shutdown_peer = true

    if not Platform.windows() then
      // Unsubscribe immediately and drop all pending writes.
      @asio_event_unsubscribe[None](_event)
      _pending.clear()
      _readable = false
      _writeable = false
    end

    // On windows, this will also cancel all outstanding IOCP operations.
    @os_closesocket[None](_fd)
    _fd = -1

    _notify.closed(this)

    try (_listen as TCPListener)._conn_closed() end
