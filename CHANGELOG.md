# Change Log

All notable changes to the Pony compiler and standard library will be documented in this file. This project adheres to [Semantic Versioning](http://semver.org/) and [Keep a CHANGELOG](http://keepachangelog.com/).

## [Unreleased][unreleased]

### Changed

- When using a package without a package identifier (eg. `use "foo"` as opposed to `use f = "foo"`), a `Main` type in the package will not be imported. This allows all packages to include unit tests that are run from their included `Main` actor without causing name conflicts.

- The `for` sugar now wraps the `next()` call in a try expression that does a `continue` if an error is raised.

### Added

- ANSI terminal handling on all platforms, including Windows.

- The lexer now allows underscore characters in numeric literals. This allows long numeric literals to be broken up for human readability.

- "Did you mean?" support when the compiler doesn't recognise a name but something similar is in scope.

### Fixed

- Check whether parameters to behaviours, actor constructors and isolated constructors are sendable after flattening, to allow sendable type parameters to be used as parameters.

- Eliminate spurious "control expression" errors when another compile error has occurred.

- Handle circular package dependencies.
