interface Hashable
  """
  Anything with a hash method is hashable.
  """
  fun hash(): U64

trait HashFunction[A] val
  """
  A pluggable hash function.
  """
  new val create()
    """
    Data structures create instances internally. Use a primitive if possible.
    """

  fun hash(x: box->A!): U64
    """
    Calculate the hash of some type. This is an alias of the type parameter to
    allow data structures to hash things without consuming them.
    """

  fun eq(x: box->A!, y: box->A!): Bool
    """
    Determine equality between two keys with the same hash. This is done with
    viewpoint adapted aliases to allow data structures to determine equality
    in a box fun without consuming keys.
    """

primitive HashEq[A: (Hashable box & Comparable[A] box)] is HashFunction[A]
  fun hash(x: box->A): U64 =>
    """
    Use the hash function from the type parameter.
    """
    x.hash()

  fun eq(x: box->A, y: box->A): Bool =>
    """
    Use the structural equality function from the type parameter.
    """
    x == y

primitive HashIs[A] is HashFunction[A]
  fun hash(x: box->A!): U64 =>
    """
    Hash the identity rather than the contents.
    """
    (&x).hash()

  fun eq(x: box->A!, y: box->A!): Bool =>
    """
    Determine equality by identity rather than structurally.
    """
    x is y
