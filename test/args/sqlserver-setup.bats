#!/usr/bin/env bats
# services/sqlserver/scripts/sqlserver-setup.sh: the password policy check (password_problem), alone and
# as the script runs it before changing anything (it fails before reaching sqlcmd, which isn't here).

load ../helpers

SCRIPT="$REPO_ROOT/services/sqlserver/scripts/sqlserver-setup.sh"

problem() { bash -c 'source "$1"; password_problem "$2" "$3"' _ "$SCRIPT" "$@"; }

@test "a password meeting the policy has no problem" {
    run problem petl 'Zx9-long-enough'
    assert_success
    assert_output ""
    run problem petl 'abc123!!'   # lower case, digits, symbols
    assert_output ""
}

@test "a password under 8 characters is refused" {
    run problem petl 'Ab1-xyz'
    assert_output "is shorter than 8 characters"
}

@test "a password with fewer than 3 character sets is refused" {
    run problem petl 'alllowercase1'
    assert_output --partial "only 2 of"
    run problem petl 'ALLUPPER'
    assert_output --partial "only 1 of"
}

@test "a password containing the login name is refused, whatever the case" {
    run problem petl 'Petl-pass1'
    assert_output "contains the login name"
    run problem Reports 'xx-REPORTS-9z'
    assert_output "contains the login name"
}

@test "an empty login skips the login-name rule" {
    run problem "" 'Sa-Placeholder-1'
    assert_output ""
}

@test "the script names the login and variable and exits before changing anything" {
    run env SQLCMDPASSWORD='Sa-Placeholder-1' SQLSERVER_LOGIN_PETL_USER=petl \
        SQLSERVER_LOGIN_PETL_PASSWORD='Petl-pass1' SQLSERVER_LOGIN_PETL_DATABASES=db1 bash "$SCRIPT"
    assert_failure
    assert_output --partial "error: the password for login petl (SQLSERVER_LOGIN_PETL_PASSWORD) contains the login name, which SQL Server refuses"
    assert_output --partial "nothing was changed"
    refute_output --partial "Petl-pass1"
}

@test "the script checks the sa password too" {
    run env SQLCMDPASSWORD='short1!' bash "$SCRIPT"
    assert_failure
    assert_output --partial "error: the password for login sa (SQLCMDPASSWORD) is shorter than 8 characters"
    refute_output --partial "short1!"
}
