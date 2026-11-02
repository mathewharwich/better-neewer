# Contributing

Run `./app/test.sh` before and after protocol or model changes, and build with `./app/build.sh`.

Keep packet framing, state parsing, device enrollment, transport and UI separate. Add a model only with source-backed capability and packet evidence. Record physical tests separately from offline fixtures and cross-compilation.

Use synthetic device IDs and MAC addresses in tests. Do not commit real device addresses, network/group IDs, saved profiles, vendor databases, account data, raw private logs or signing credentials. Include a small sanitized trace when useful.

For BLE changes, require explicit enrollment, handle duplicate model names, validate identity/address before setters, serialize writes, coalesce slider updates and preserve manual disconnection. Discovery, refresh, connection, wake and UI appearance must never set output.

For UI changes, check the empty state, many lights, repeated models, offline/unknown/pending states, numeric editing, rename/removal, scrolling and close/reopen without quitting. A Bluetooth acknowledgment must not become a reported-value label.

For hardware testing, record the baseline, identify the intended fixture, make a small explicit change, observe it physically and restore the baseline. Describe exactly which hardware/firmware and architectures you tested in the pull request.
