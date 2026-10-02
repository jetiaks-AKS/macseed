# Bootstrap Modules

Bootstrap combines Generated Configuration with Blueprint selection to reconstruct
supported environment state safely and idempotently. Consumers validate required
selected input, inspect target state, apply necessary changes and verify observable
results: **Check → Apply → Verify**.

Observation failures are not absence; matching state is no-op and unsafe conflicts
preserve user data. Global Verification reports selected conformity separately
from operation outcomes. See [Configuration](../../docs/toolkit/CONFIGURATION.md)
for domain contracts and [Workspace](workspace/README.md) for local responsibilities.
