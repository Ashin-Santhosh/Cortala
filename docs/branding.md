# JustWhisper naming

The application is named **JustWhisper**, one word, with the h in Whisper. Its installed bundle, executable, menu/sidebar text, icon asset and distributable ZIP use this spelling.

Compatibility identities deliberately retain the earlier spelling: com.justwisper.app, the JustWisper Swift module and source/test directories, Application Support/JustWisper, Keychain service com.justwisper.credentials, the vault file header, CLI entry point, local helper protocol and configuration-sync filenames. Changing those identities as a cosmetic rename could strand recordings, encrypted libraries, keys or existing integrations. Existing data is reused in place rather than copied into a second library. The workspace folder remains SuperWisper.

Git tracking began with the pre-rename baseline. The naming change is a separate commit; earlier uncommitted work cannot be reconstructed as historical commits.
