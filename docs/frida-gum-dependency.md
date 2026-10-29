# IPA-only Frida Gum dependency

`Tools/build-ipa-deb.sh` fetches the official Frida Gum **17.24.3 iOS arm64
devkit** from the [Frida release](https://github.com/frida/frida/releases/tag/17.24.3)
and verifies the archive and extracted library/header by SHA-256. The library
is statically linked only into the IPA/Internal backend; rootless packages
continue to use their existing function-hook backend. Build cache files under
`Outputs/dependencies/` are ignored and are not source-controlled.

Frida Gum's [upstream license](https://github.com/frida/frida/blob/17.24.3/COPYING)
is the wxWindows Library Licence, Version 3.1, with a binary-linking exception.
The verbatim license text is in [`docs/third-party/Frida-Gum-COPYING`](third-party/Frida-Gum-COPYING).
Preserve this notice and the source/version attribution when distributing an
IPA containing the statically linked library. `Tools/graft-ipa-playplay.sh`
copies the notice into the final app bundle for that reason. The devkit's example and header
are supplied by Frida's official release; no Gum source is modified here.

The static C probe avoids a bundled Frida Gadget's script loader and listening
service. It still requires a valid ahead-of-time graft in an exact, decrypted
Spotify 9.1.88 executable and a successful strict-code-signing attach; an IPA
build alone does not establish either runtime condition.
