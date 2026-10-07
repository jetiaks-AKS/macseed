#!/bin/bash
# Executed by sudo -A only. The masked response goes directly to sudo's pipe;
# never enable xtrace, echo it to diagnostics, or expose it to Protocol output.
set +x
exec /usr/bin/osascript -e 'try
    set response to display dialog "Macseed: authorize the reviewed Homebrew Cask lifecycle. Homebrew may install packages and perform declared cleanup with administrator privileges." default answer "" with hidden answer buttons {"Cancel", "Authorize"} default button "Authorize" cancel button "Cancel" with icon caution
    return text returned of response
on error
    error number -128
end try'
