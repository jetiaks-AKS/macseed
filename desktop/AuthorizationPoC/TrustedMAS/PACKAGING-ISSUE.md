# Production packaging gate: application parent permissions

During the earlier local development checkpoint, both the initial component pkg
and layout2 installed the app under
/Library/Application Support/MacseedTrustedMASPoC-App, but the existing parent
remained root:wheel 0700. The GUI was inaccessible to the ordinary user. Even the
layout2 BOM describing 0755 did not establish the desired installed permissions.
The exact Installer metadata/preservation cause remains unqualified.

The user corrected that single directory manually to 0755. Read-only checks in
the resumed test confirmed root ownership, accessible signed app and successful
SMAppService registration. No layout3 package or native postinstall was deployed.
This manual correction is not a production installation solution.

Before production delivery, qualify fresh install and upgrade over existing
directories, actual parent ownership/modes/ACLs, ordinary-user GUI launch,
protected helper/artifact execution and uninstall behavior. Verify the installed
filesystem rather than treating package BOM metadata as acceptance evidence.
Do not change /Applications or other global permissions to solve the layout.
