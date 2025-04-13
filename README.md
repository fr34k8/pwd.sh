pwd.sh is a Bash shell script to manage text-based secrets, such as passwords.

It uses GnuPG to symmetrically (i.e., using a passphrase) encrypt and decrypt plaintext files.

Each secret is individually encrypted to a randomly-named file in the *safe* directory. An encrypted index is used to map usernames to the respective secret file. Both the index and secret files can be decrypted with GnuPG without requiring pwd.sh.

# Install

For the latest version, clone the repository or download the script directly:

```console
git clone https://github.com/drduh/pwd.sh

wget https://raw.githubusercontent.com/drduh/pwd.sh/master/pwd.sh
```

Versioned [Releases](https://github.com/drduh/pwd.sh/releases) are also available.

# Use

Run the script interactively using `./pwd.sh` or symlink to a directory in `PATH`:

- `w` to create a secret
- `r` to access a secret
- `l` to list all secrets
- `b` to create a backup archive
- `h` to print the help text

Options can also be passed on the command line.

Create a 20-character password for `userName`:

```console
./pwd.sh w userName 20
```

Read password for `userName`:

```console
./pwd.sh r userName
```

Passwords are stored with an epoch timestamp for revision control. The most recent version is copied to clipboard on read. To list all passwords or read a specific version of a password:

```console
./pwd.sh l

./pwd.sh r userName@1574723600
```

Create an archive for backup:

```console
./pwd.sh b
```

Restore an archive from backup:

```console
tar xvf pwd*tar
```

# Configure

Several customizable options and features are also available, and can be configured with environment variables, for example in the [shell rc](https://github.com/drduh/config/blob/main/zshrc) file:

Variable | Description | Default | Available options
---: | :---: | :---: | :---
`PWDSH_CLIP` | clipboard to use | `xclip` | `pbcopy` on macOS
`PWDSH_CLIP_ARGS` | arguments to pass to clipboard command | unset (disabled) | `-i -selection clipboard` to use primary (control-v) clipboard with xclip
`PWDSH_TIME` | seconds to clear password from clipboard/screen | `10` | any valid integer
`PWDSH_LEN` | default password length | `14` | any valid integer
`PWDSH_COPY` | copy password to clipboard before write | unset (disabled) | `1` or `true` to enable
`PWDSH_DAILY` | create daily backup archive on write | unset (disabled) | `1` or `true` to enable
`PWDSH_CHARS` | character set for passwords | `[:alnum:]!?@#$%^&*();:+=` | any valid characters
`PWDSH_COMMENT` | **unencrypted** comment to include in index and safe files | unset | any valid string
`PWDSH_DEST` | password output destination, will set to `screen` without clipboard | `clipboard` | `clipboard` or `screen`
`PWDSH_ECHO` | character used to echo password input | `*` | any valid character
`PWDSH_SAFE` | safe directory name | `safe` | any valid string
`PWDSH_INDEX` | index file name | `pwd.index` | any valid string
`PWDSH_BACKUP` | backup archive file name | `pwd.$hostname.$today.tar` | any valid string
`PWDSH_PEPPER` | file containing [Pepper](#Pepper) | unset (disabled) | any valid file path

See [config/gpg.conf](https://github.com/drduh/config/blob/main/gpg.conf) for additional GnuPG options.

Also see [drduh/Purse](https://github.com/drduh/Purse) - a fork which integrates with [YubiKey](https://github.com/drduh/YubiKey-Guide) instead of using a passphrase.

# Pepper

The [Pepper](https://www.wikipedia.org/wiki/Pepper_(cryptography)) is an additional string appended to the safe passphrase to improve its strength. When the `PWDSH_PEPPER` option is set to a valid path, a secret value is generated and displayed once, then saved to the respective file.

The Pepper should be written down (for example, transcribed with [passphrase.html](https://raw.githubusercontent.com/drduh/YubiKey-Guide/master/templates/passphrase.html) or [passphrase.txt](https://raw.githubusercontent.com/drduh/YubiKey-Guide/master/templates/passphrase.txt) template) and stored in a secure, durable location for backup.

This feature may enable use of a more memorable - and possibly weaker passphrase - for convenience, while still guarding backups against passphrase brute-force attempts (provided the Pepper is backed up separately).

The Pepper feature is opt-in and has no effect unless explicitly enabled.

> [!WARNING]
> The Pepper is **not** included in backup archives! Without the Pepper, the safe will **not** be accessible with the safe passphrase alone!
