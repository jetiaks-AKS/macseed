"""Compatibility entrypoint for the concrete Homebrew owned-item provider."""
from adapters.homebrew_items import BrewItemExecutor, valid_name, main

if __name__ == '__main__':
    import sys
    sys.exit(main())
