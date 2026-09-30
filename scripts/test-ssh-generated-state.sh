#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)" || exit 2
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
export HOME="$TEST_ROOT/home"
SSH_SNAPSHOT_FILE="$TEST_ROOT/config/generated/ssh/config.snapshot"
BLUEPRINT_FILE="$TEST_ROOT/config/blueprint.conf"
mkdir -p "$HOME"
source "$PROJECT_ROOT/modules/ssh/config.sh"
source "$PROJECT_ROOT/modules/discovery/discovery.sh"
source "$PROJECT_ROOT/modules/discovery/ssh.sh"
source "$PROJECT_ROOT/modules/blueprint/blueprint.sh"
success() { :; }; warning() { WARNINGS=$((WARNINGS + 1)); }; error() { :; }
preview_action() { PLAN="$1"; }
FAILURES=0
WARNINGS=0
PLAN=""
MODULE_CHANGED=false
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
expect() { local label="$1" expected="$2"; shift 2; "$@"; local got=$?; [[ $got -eq $expected ]] && pass "$label" || fail "$label (status $got, expected $expected)"; }
reset_fixture() {
    rm -rf "$HOME/.ssh" "$TEST_ROOT/config"
    mkdir -p "$TEST_ROOT/config/generated/ssh"
    WARNINGS=0; PLAN=""; MODULE_CHANGED=false
}
source_config() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    printf '%s' "$1" > "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
}
snapshot_status() {
    local p
    p="$(mktemp)" || return 2
    ssh_snapshot_validate "$p"
    local result=$?
    rm -f "$p"
    [[ $result -eq 0 && "$SSH_SNAPSHOT_STATUS" == "$1" && "$SSH_SNAPSHOT_COUNT" == "$2" ]]
}
valid_profile=$'Host example\n HostName example.invalid\n'

reset_fixture
expect 'absent SSH directory Discovery' 0 discover_ssh_configuration
snapshot_status absent-directory 0 && pass 'absent-directory status' || fail 'absent-directory status'
reset_fixture
mkdir -m 700 "$HOME/.ssh"
expect 'absent config Discovery' 0 discover_ssh_configuration
snapshot_status absent-config 0 && pass 'absent-config status' || fail 'absent-config status'
reset_fixture
source_config ''
expect 'empty config Discovery' 0 discover_ssh_configuration
snapshot_status empty 0 && pass 'empty status' || fail 'empty status'
reset_fixture
source_config "$valid_profile"
expect 'one profile Discovery' 0 discover_ssh_configuration
snapshot_status ready 1 && pass 'ready status' || fail 'ready status'
source_config "$valid_profile"$'\nHost second\n HostName second.invalid\n'
expect 'two profile Discovery' 0 discover_ssh_configuration
snapshot_status ready 2 && pass 'two profile count' || fail 'two profile count'

reset_fixture
source_config $'# comment\n\n HOST example  \r\n hostname example.invalid\r\n User admin\r\n Port 65535\r\n ServerAliveInterval 3600\r\n ServerAliveCountMax 20\r\n TCPKeepAlive no\r\n ConnectTimeout 300'
expect 'all allowed directives, CRLF and missing final newline' 0 discover_ssh_configuration
snapshot_status ready 1 && pass 'canonical allowed profile' || fail 'canonical allowed profile'

reset_fixture
source_config $'# Русский комментарий — допустим и не экспортируется\n\nHost example\n HostName example.invalid\n User admin\n'
expect 'Unicode SSH comment Discovery' 0 discover_ssh_configuration
snapshot_status ready 1 && pass 'Unicode SSH comment accepted' || fail 'Unicode SSH comment rejected'

if grep -q 'Русский' "$SSH_SNAPSHOT_FILE"; then
    fail 'Unicode SSH comment leaked into snapshot'
else
    pass 'Unicode SSH comment not serialized'
fi

reset_fixture
source_config $'Host first\n HostName first.invalid\n Port 9\n ServerAliveInterval 9\n ServerAliveCountMax 9\n ConnectTimeout 9\n\nHost second\n HostName second.invalid\n User admin\n\nHost excluded\n HostName excluded.invalid\n IdentityFile unsupported\n'
expect 'numeric values and unsupported profile Discovery' 1 discover_ssh_configuration
snapshot_status partial 2 && [[ "$SSH_SNAPSHOT_EXCLUDED" == 1 ]] && pass 'numeric comparisons retain both eligible profiles' || fail 'numeric comparisons excluded an eligible profile'

for directive in 'IdentityFile ~/.ssh/id_test' 'IdentitiesOnly yes' 'UseKeychain yes' 'AddKeysToAgent yes' 'Compression yes' 'ProxyJump jump' 'ProxyCommand command' 'LocalForward 1 2' 'RemoteForward 1 2' 'DynamicForward 1' 'ForwardAgent yes' 'RemoteCommand command' 'LocalCommand command' 'SetEnv X=Y' 'SendEnv X' 'UnknownDirective value' 'Port 0' 'ServerAliveCountMax 100' 'ConnectTimeout 301' 'Port 22 # note' 'User "admin"' 'User admin\path' 'User=admin' 'Port 22' ; do
    reset_fixture
    source_config "$valid_profile"" $directive"$'\n'
    [[ "$directive" != 'Port 22' ]] || source_config "$valid_profile"$' Port 22\n Port 22\n'
    expect "unsupported profile: ${directive%% *}" 1 discover_ssh_configuration
    snapshot_status unsupported 0 && pass 'unsupported-only status' || fail 'unsupported-only status'
done

reset_fixture
source_config "$valid_profile"$'\nHost excluded\n HostName excluded.invalid\n IdentityFile ~/.ssh/id_test\n'
expect 'partial source Discovery' 1 discover_ssh_configuration
snapshot_status partial 1 && pass 'partial status' || fail 'partial status'

for source in $'Host *\n HostName example.invalid\n' $'Host !example\n HostName example.invalid\n' $'Host one two\n HostName example.invalid\n' $'Match exec command\n' $'Include other.conf\n' $'User admin\nHost example\n HostName example.invalid\n' $'Host example\n HostName example.invalid\nHost example\n HostName other.invalid\n'; do
    reset_fixture
    source_config "$source"
    expect 'whole-source hazard' 1 discover_ssh_configuration
    snapshot_status unsupported 0 && pass 'hazard excluded all profiles' || fail 'hazard excluded all profiles'
done

reset_fixture
source_config "$valid_profile"
expect 'seed prior snapshot' 0 discover_ssh_configuration
cp "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/prior"
source_config $'Host example\nmalformed\n'
expect 'malformed source fails' 2 discover_ssh_configuration
cmp -s "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/prior" && pass 'Safe Publication preserves prior snapshot' || fail 'prior snapshot changed'
source_config "$valid_profile"
printf '\000' >> "$HOME/.ssh/config"
expect 'NUL source fails' 2 discover_ssh_configuration
cmp -s "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/prior" && pass 'NUL preserves prior snapshot' || fail 'NUL changed snapshot'
source_config "$valid_profile"$'\001'
expect 'control byte source fails' 2 discover_ssh_configuration
source_config "$valid_profile"$'\rHost second\n HostName second.invalid\n'
expect 'bare CR source fails' 2 discover_ssh_configuration

reset_fixture
source_config "$valid_profile"
expect 'seed valid snapshot for target' 0 discover_ssh_configuration
rm -rf "$HOME/.ssh"
expect 'Preview absent target' 0 preview_ssh_configuration
[[ "$PLAN" == 'Would restore SSH configuration: 1 eligible profiles' ]] && pass 'Preview aggregate plan' || fail 'Preview plan'
[[ ! -e "$HOME/.ssh" ]] && pass 'Preview did not mutate target' || fail 'Preview mutated target'
expect 'Bootstrap clean target' 0 bootstrap_ssh_configuration
[[ "$MODULE_CHANGED" == true && "$(stat -f '%Lp' "$HOME/.ssh")" == 700 && "$(stat -f '%Lp' "$HOME/.ssh/config")" == 600 ]] && pass 'created modes and change accounting' || fail 'created modes/accounting'
MODULE_CHANGED=false
expect 'second identical Bootstrap' 0 bootstrap_ssh_configuration
[[ "$MODULE_CHANGED" == false ]] && pass 'second run no-op' || fail 'second run mutated'
printf '# target owner content\n' > "$HOME/.ssh/config"
expect 'different target preserved' 1 bootstrap_ssh_configuration
[[ "$(cat "$HOME/.ssh/config")" == '# target owner content' ]] && pass 'conflict bytes preserved' || fail 'conflict overwritten'
rm -f "$HOME/.ssh/config"
ln -s "$TEST_ROOT/prior" "$HOME/.ssh/config"
expect 'target symlink refused' 1 bootstrap_ssh_configuration
rm "$HOME/.ssh/config"
printf 'other\n' > "$HOME/.ssh/config"
chmod 644 "$HOME/.ssh/config"
expect 'wrong target mode refused' 1 bootstrap_ssh_configuration
rm -f "$HOME/.ssh/config"
chmod 755 "$HOME/.ssh"
expect 'wrong target directory mode refused' 1 bootstrap_ssh_configuration
chmod 700 "$HOME/.ssh"

reset_fixture
source_config "$valid_profile"
expect 'new snapshot for malformed tests' 0 discover_ssh_configuration
for replacement in '# toolkit-ssh-snapshot: 2' '# status: bogus' '# excluded-profiles: x'; do
    cp "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/good"
    sed "1s/.*/$replacement/" "$TEST_ROOT/good" > "$SSH_SNAPSHOT_FILE"
    chmod 600 "$SSH_SNAPSHOT_FILE"
    p="$(mktemp)"; expect 'malformed snapshot rejected' 2 ssh_snapshot_validate "$p"; rm -f "$p"
    cp "$TEST_ROOT/good" "$SSH_SNAPSHOT_FILE"
done

cp "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/good-snapshot"
for payload_line in '    IdentityFile private' '    HostName another.invalid' 'Host example' '    Port 22 # comment'; do
    cp "$TEST_ROOT/good-snapshot" "$SSH_SNAPSHOT_FILE"
    printf '%s\n' "$payload_line" >> "$SSH_SNAPSHOT_FILE"
    p="$(mktemp)"; expect 'invalid generated payload rejected' 2 ssh_snapshot_validate "$p"; rm -f "$p"
done
cp "$TEST_ROOT/good-snapshot" "$SSH_SNAPSHOT_FILE"
chmod 644 "$SSH_SNAPSHOT_FILE"
p="$(mktemp)"; expect 'wrong generated mode rejected' 2 ssh_snapshot_validate "$p"; rm -f "$p"
chmod 600 "$SSH_SNAPSHOT_FILE"
mv "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/real-snapshot"
ln -s "$TEST_ROOT/real-snapshot" "$SSH_SNAPSHOT_FILE"
p="$(mktemp)"; expect 'symlink generated snapshot rejected' 2 ssh_snapshot_validate "$p"; rm -f "$p"
rm "$SSH_SNAPSHOT_FILE"
cp "$TEST_ROOT/real-snapshot" "$SSH_SNAPSHOT_FILE"

rm -f "$BLUEPRINT_FILE"
expect 'no Blueprint enables SSH category' 0 blueprint_category_enabled ssh-configuration
cp "$PROJECT_ROOT/config/blueprint.example.conf" "$BLUEPRINT_FILE"
sed -i '' '/^ssh-configuration=/d' "$BLUEPRINT_FILE"
expect 'old Blueprint disables SSH category' 1 blueprint_category_enabled ssh-configuration
sed -i '' '/^git-configuration=/a\
ssh-configuration="true"\
' "$BLUEPRINT_FILE"
expect 'explicit SSH category enabled' 0 blueprint_category_enabled ssh-configuration
expect 'enabled Blueprint syntax' 0 blueprint_validate_syntax "$BLUEPRINT_FILE"
sed -i '' 's/ssh-configuration="true"/ssh-configuration="false"/' "$BLUEPRINT_FILE"
expect 'explicit SSH category disabled' 1 blueprint_category_enabled ssh-configuration
rm -f "$BLUEPRINT_FILE"

reset_fixture
source_config "$valid_profile"$'\nHost excluded\n HostName excluded.invalid\n IdentityFile missing\n'
expect 'partial snapshot for private Preview' 1 discover_ssh_configuration
rm -rf "$HOME/.ssh"
PLAN=""; WARNINGS=0
expect 'partial Preview' 1 preview_ssh_configuration
[[ "$PLAN" == 'Would restore SSH configuration: 1 eligible profiles' && $WARNINGS -eq 1 ]] && pass 'partial Preview aggregate warning and plan' || fail 'partial Preview output'
[[ "$PLAN" != *example* && "$PLAN" != *excluded* && ! -e "$HOME/.ssh" ]] && pass 'Preview privacy and non-mutation' || fail 'Preview leaked or mutated'
source_config "$valid_profile"$'\nHost excluded\n HostName excluded.invalid\n IdentityFile private\n'
cp "$HOME/.ssh/config" "$TEST_ROOT/partial-target-before"
expect 'partial Preview preserves existing target conflict' 1 preview_ssh_configuration
expect 'partial Bootstrap preserves existing target conflict' 1 bootstrap_ssh_configuration
cmp -s "$HOME/.ssh/config" "$TEST_ROOT/partial-target-before" && pass 'partial target bytes preserved' || fail 'partial target overwritten'

reset_fixture
source_config "$valid_profile"
expect 'snapshot for race tests' 0 discover_ssh_configuration
rm -rf "$HOME/.ssh"
ln() { printf 'concurrent target\n' > "$HOME/.ssh/config"; return 1; }
expect 'concurrent target appearance' 1 bootstrap_ssh_configuration
unset -f ln
[[ "$(cat "$HOME/.ssh/config")" == 'concurrent target' && "$MODULE_CHANGED" == true ]] && pass 'no-clobber and directory change accounting' || fail 'concurrent target overwritten'
rm -f "$HOME/.ssh/config"
MODULE_CHANGED=false
mktemp() { [[ "${1:-}" != "$HOME/.ssh/config.tmp."* ]] || return 1; command mktemp "$@"; }
expect 'staging failure' 2 bootstrap_ssh_configuration
unset -f mktemp
[[ "$MODULE_CHANGED" == false && ! -e "$HOME/.ssh/config" ]] && pass 'failed staging makes no target write' || fail 'failed staging changed target'
ln() { command ln "$@" || return; printf 'corrupted\n' > "$HOME/.ssh/config"; }
expect 'post-publication Verify failure' 2 bootstrap_ssh_configuration
unset -f ln
[[ "$MODULE_CHANGED" == true ]] && pass 'Verify failure retains write accounting' || fail 'Verify failure lost write accounting'

reset_fixture
source_config "$valid_profile"
expect 'snapshot before symlink source' 0 discover_ssh_configuration
cp "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/last-good"
mv "$HOME/.ssh/config" "$TEST_ROOT/external-config"
ln -s "$TEST_ROOT/external-config" "$HOME/.ssh/config"
expect 'symlink source excluded' 1 discover_ssh_configuration
snapshot_status external 0 && pass 'external status' || fail 'external status'
rm "$HOME/.ssh/config"
mkdir "$HOME/.ssh/config"
expect 'unexpected source type fails' 2 discover_ssh_configuration

reset_fixture
source_config "$valid_profile"
expect 'snapshot before source change' 0 discover_ssh_configuration
cp "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/last-good"
eval "$(declare -f ssh_config_parse | sed '1s/ssh_config_parse/ssh_config_parse_original/')"
ssh_config_parse() { ssh_config_parse_original "$@"; local result=$?; [[ "${3:-}" != source ]] || printf '# changed\n' >> "$1"; return "$result"; }
expect 'source change during observation fails' 2 discover_ssh_configuration
unset -f ssh_config_parse
eval "$(declare -f ssh_config_parse_original | sed '1s/ssh_config_parse_original/ssh_config_parse/')"
cmp -s "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/last-good" && pass 'source race preserves prior snapshot' || fail 'source race published snapshot'

reset_fixture

source_config "$valid_profile"

expect 'snapshot before SSH directory substitution' 0 discover_ssh_configuration
cp "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/directory-race-last-good"

eval "$(declare -f ssh_config_parse | sed '1s/ssh_config_parse/ssh_config_parse_original/')"

ssh_config_parse() {
    ssh_config_parse_original "$@"
    local result=$?

    if [[ "${3:-}" == source ]]; then
        mv "$HOME/.ssh" "$HOME/.ssh.original"
        mkdir -m 700 "$HOME/.ssh"
        cp "$HOME/.ssh.original/config" "$HOME/.ssh/config"
        chmod 600 "$HOME/.ssh/config"
    fi

    return "$result"
}

expect 'SSH directory substitution during observation fails' 2 discover_ssh_configuration

unset -f ssh_config_parse
eval "$(declare -f ssh_config_parse_original | sed '1s/ssh_config_parse_original/ssh_config_parse/')"
unset -f ssh_config_parse_original

cmp -s "$SSH_SNAPSHOT_FILE" "$TEST_ROOT/directory-race-last-good" &&
    pass 'SSH directory race preserves prior snapshot' ||
    fail 'SSH directory race published snapshot'

[[ $FAILURES -eq 0 ]] || exit 1
echo 'SSH generated-state tests passed'
