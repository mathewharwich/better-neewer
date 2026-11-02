# Privacy

Better Neewer controls supported lights locally through macOS Bluetooth. It has no account, analytics, advertising, cloud service or built-in updater.

The app stores the lights you explicitly add, their CoreBluetooth identifiers, hardware addresses, display names and remembered settings locally in `~/Library/Application Support/Better Neewer/profiles-v2.json`.

During setup it reads local macOS Bluetooth metadata to resolve a selected fixture's address. It does not upload that metadata. Only supported discovered fixtures are offered for enrollment, and adding a profile requires your action. Discovery and connection do not set output.

Removing a local profile removes it from this app's saved list; it does not reset, unpair or change the light. Quitting leaves the light's last output unchanged.

If you submit an issue, sanitize screenshots and logs before uploading them to GitHub. Issue content is public unless you use a private reporting channel. GitHub and your operating system have their own privacy policies.
