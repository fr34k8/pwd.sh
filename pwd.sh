#!/usr/bin/env bash
# https://github.com/drduh/pwd.sh/blob/master/pwd.sh

#set -x  # uncomment to debug
set -o errtrace
set -o nounset
set -o pipefail

umask 077
export LC_ALL="C"

gpg="$(command -v gpg || command -v gpg2)"
gpg_dir="${HOME}/.gnupg"
gpg_conf="${gpg_dir}/gpg.conf"

now="$(date +%s)"
today="$(date +%F)"

vers="v4"
name="$(basename "$0")"
app="${vers}-${name}"

backup="${app}.$(hostname).${today}.tar"
safe_backup="${PWDSH_BACKUP:=${backup}}" # backup archive
safe_dir="${PWDSH_SAFE:=${app}.secret}"  # safe directory
safe_ix="${PWDSH_INDEX:=${app}.index}"   # index file
pepper="${PWDSH_PEPPER:=}"               # optional pepper file

clip_cmd="${PWDSH_CLIP:=xclip}"       # clipboard, 'pbcopy' on macOS
clip_args="${PWDSH_CLIP_ARGS:=}"      # args to pass to clip command
clip_dest="${PWDSH_DEST:=clipboard}"  # cb type, 'screen' for stdout
clip_timeout="${PWDSH_TIME:=10}"      # seconds to clear cb/screen
daily_backup="${PWDSH_DAILY:=}"       # daily backup archive on write
pass_copy="${PWDSH_COPY:=}"           # copy password before write
pass_echo="${PWDSH_ECHO:=*}"          # show "*" when typing passwords
pass_len="${PWDSH_LEN:=20}"           # default password length
pub_comment="${PWDSH_PUBCOMMENT:=}"   # public/plaintext file comment

pass_chars="${PWDSH_CHARS:='[:alnum:]!?@#$%^&*();:+='}"

trap cleanup EXIT INT TERM
cleanup() {
  # "Lock" files on trapped exits.

  ret=$?
  chmod -R 0000 "${pepper}" "${safe_dir}" "${safe_ix}" 2>/dev/null
  exit ${ret}
}

timestamp() {
  # Format current date and time.

  date +"%A %b %d %H:%M:%S"
}

fail() {
  # Print error message in red and exit with failure.

  tput setaf 1 ; printf "($(timestamp)) %s\n" "${1}" ; \
  tput sgr0
  exit 1
}

final() {
  # Print final message in green and exit with success.

  tput setaf 2 ; printf "($(timestamp)) %s\n" "${1}" ; \
  tput sgr0
  exit 0
}

warn() {
  # Print warning message in yellow.

  tput setaf 3 ; printf "WARNING: %s\n" "${1}" ; \
  tput sgr0
}

generatePepper() {
  # Generate, display and save "pepper" secret value.

  warn "created ${pepper} - copy to secure storage:"
  printf "%s\n" \
    "$(tr -dc 'A-Y2-9' < /dev/urandom | tr -d "IOS5UB" | \
    fold -w 6 | paste -sd - - | head -c 27)" | \
  tee "${pepper}" || fail "Failed writing ${pepper}"
}

promptPassword() {
  # Prompt for a password.

  password=""
  prompt="${1}"

  while IFS= read -p "${prompt}" -r -s -n 1 char ; do
    if [[ ${char} == $'\0' ]] ; then break
    elif [[ ${char} == $'\177' ]] ; then
      if [[ -z "${password}" ]] ; then prompt=""
      else
        prompt=$'\b \b'
        password="${password%?}"
      fi
    else
      prompt="${pass_echo}"
      password+="${char}"
    fi
  done

  printf "\n"
}

decrypt() {
  # Decrypt with GPG.

  printf "%s" "${1}${pep}" | \
    ${gpg} --armor --batch \
    --decrypt --no-symkey-cache \
    --passphrase-fd 0 \
    "${2}" 2>/dev/null
}

encrypt() {
  # Encrypt with GPG.

  ${gpg} --armor --batch --yes \
    --symmetric \
    --comment "${pub_comment}" \
    --passphrase-fd 3 \
    --output "${2}" "${3}" 3< \
    <(printf "%s" "${1}${pep}") 2>/dev/null
}

readSecret() {
  # Read a secret from safe.

  verifyIndex

  while [[ -z "${username}" ]] ; do
    if [[ -z "${2+x}" ]] ; then read -r -p \
      "Username: " username
    else username="${2}" ; fi
  done

  promptPassword "Password to access ${safe_ix}: "

  spath=$(decrypt "${password}" "${safe_ix}" | \
    grep -F "${username}" | tail -1 | cut -d ":" -f2) || \
      fail "Secret not available"

  revealPass <(decrypt "${password}" "${spath}") || \
    fail "Failed to decrypt ${spath}"
}

generateSecret() {
  # Generate a secret from urandom.

  if [[ -z "${3+x}" ]] ; then read -r -p \
    "Secret length (default: ${pass_len}): " length
  else length="${3}" ; fi

  if [[ "${length}" =~ ^[0-9]+$ ]] ; then
    pass_len="${length}" ; fi

  tr -dc "${pass_chars}" < /dev/urandom | \
    fold -w "${pass_len}" | head -1
}

generateUsername() {
  # Generate a username.

  printf "%s%s\n" \
    "$(awk 'length > 2 && length < 12 {print(tolower($0))}' \
    /usr/share/dict/words | grep -v "'" | sort -R | head -n2 | \
    tr "\n" "-" | iconv -f utf-8 -t ascii//TRANSLIT)" \
    "$(tr -dc "[:digit:]" < /dev/urandom | fold -w 3 | head -1)"
}

writeSecret() {
  # Write a secret and update the index.

  sname="$(tr -dc "[:lower:]" < /dev/urandom | \
    fold -w 10 | head -1)"
  spath="${safe_dir}/${app}.${sname}"

  if [[ -n "${pass_copy}" ]] ; then
    revealPass <(printf '%s' "${userpass}") ; fi

  promptPassword "Password to access ${safe_ix}: "

  printf '%s\n' "${userpass}" | \
    encrypt "${password}" "${spath}" - || \
      fail "Failed saving ${spath}"

  { if [[ -f "${safe_ix}" ]]; then
      decrypt "${password}" "${safe_ix}" || return
    fi
    printf "%s@%s:%s\n" "${username}" "${now}" "${spath}"
  } | encrypt "${password}" "${safe_ix}.${now}" -

  if ! mv "${safe_ix}.${now}" "${safe_ix}"; then
    fail "Failed saving ${safe_ix}.${now}" ; fi
}

listSecrets() {
  # Decrypt the index to list secrets.

  verifyIndex

  promptPassword "Password to access ${safe_ix}: "
  decrypt "${password}" "${safe_ix}" || \
    fail "${safe_ix} not available"
}

backup() {
  # Archive index, safe and configuration.

  gpg_conf_copy="${app}.gpg.conf"
  if [[ ! -f "${safe_backup}" ]] ; then
    if [[ -f "${safe_ix}" && -d "${safe_dir}" ]] ; then
      cp "${gpg_conf}" "${gpg_conf_copy}"
      tar cvf "${safe_backup}" "${safe_dir}" "${safe_ix}" \
        "${BASH_SOURCE}" "${gpg_conf_copy}" ||
          fail "Failed archiving to ${safe_backup}"
        final "Archived ${safe_backup}"
    else fail "Nothing to archive" ; fi
  else fail "Skipping archive - ${safe_backup} exists" ; fi
}

revealPass() {
  # Reveal secret to clipboard or stdout and
  # clear after timeout.

  if [[ "${clip_dest}" = "screen" ]] ; then
    printf '\n%s\n' "$(cat "${1}")"
  else ${clip_cmd} < "${1}" ; fi

  printf "\n"
  while [[ "${clip_timeout}" -gt 0 ]] ; do
    printf "\r\033[KSecret on %s! Clearing in %.d" \
      "${clip_dest}" "$((clip_timeout--))" ; sleep 1
  done
  printf "\r\033[KClearing password from %s ..." \
    "${clip_dest}"

  if [[ "${clip_dest}" = "screen" ]] ; then clear
  else printf "\n" ; printf "" | ${clip_cmd} ; fi
}

newSecret() {
  # Prompt for username and password.

  if [[ -z "${2+x}" ]] ; then read -r -p \
    "Username (Enter to generate): " username
  else username="${2}" ; fi

  if [[ -z "${username}" ]] ; then
    username=$(generateUsername "$@") ; fi

  if [[ -z "${3+x}" ]] ; then
    promptPassword "Secret for \"${username}\" (Enter to generate): "
    userpass="${password}" ; fi

  if [[ -z "${password}" ]] ; then
    userpass=$(generateSecret "$@") ; fi
}

verifyIndex() {
  # Verify the index file exists and is non-empty.

  [[ -s "${safe_ix}" ]] || fail "${safe_ix} not found"
}

printHelp() {
  printf '%s\n' """Available options:
  r - read (access) a secret
  w - write (create) a secret
  l - list all secret names and paths
  b - archive materials for backup
  s - generate a random secret value
  u - generate a random username
  v - print script version
  h - print help text

  Write 20-character secret for 'userName'
    ./pwd.sh w userName 20

  Read secret for 'userName'
    ./pwd.sh r userName

  Read version of secret for 'usernName'
    ./pwd.sh r userName@1574723625

  Create an archive for backup
    ./pwd.sh b"""
}

initGnuPG() {
  [[ -n "${gpg}" ]]      || fail "GnuPG binary not available"
  [[ -f "${gpg_conf}" ]] || fail "GnuPG config not available"
}

initStorage() {
  if [[ ! -d "${safe_dir}" ]] ; then mkdir -p "${safe_dir}" ; fi
  chmod -R 0700 "${pepper}" "${safe_dir}" "${safe_ix}" 2>/dev/null
}

initPepper() {
  if [[ -n "${pepper}" && ! -f "${pepper}" ]] ; then
    generatePepper ; fi
  if [[ -f "${pepper}" ]] ; then
    pep="$(cat "${pepper}")" ; else pep="" ; fi
}

initClipboard() {
  if [[ -z "$(command -v "${clip_cmd}")" ]] ; then
    warn "Clipboard not available - secrets will appear on screen/stdout!"
    clip_dest="screen"
  elif [[ -n "${clip_args}" ]] ; then
    clip+=" ${clip_args}" ; fi
}

initOps() {
  initGnuPG
  initStorage
  initPepper
  initClipboard
}

activity=""
if [[ -n "${1+x}" ]] ; then activity="${1}" ; fi
while [[ -z "${activity}" ]] ; do read -r -n 1 -p \
  "Available options:
  [W]rite, [R]read or [L]ist secrets
  Generate [S]ecret or [U]sername values
  Archive materials for [B]ackup
  Print app [V]ersion or [H]elp information
Select an option: " activity
  printf "\n"
done

if [[ "${activity}" =~ ^([bB])$ ]] ; then
  backup
elif [[ "${activity}" =~ ^([hH])$ ]] ; then
  final "$(printHelp)"
elif [[ "${activity}" =~ ^([uU])$ ]] ; then
  final "Username: $(generateUsername)"
elif [[ "${activity}" =~ ^([sS])$ ]] ; then
  final "Secret: $(generateSecret $@)"
elif [[ "${activity}" =~ ^([vV])$ ]] ; then
  final "Version: ${app}" ; fi

initOps

username=""
password=""

if [[ "${activity}" =~ ^([rR])$ ]] ; then
  readSecret "$@"
elif [[ "${activity}" =~ ^([lL])$ ]] ; then
  listSecrets
elif [[ "${activity}" =~ ^([wW])$ ]] ; then
  newSecret "$@"
  writeSecret
  if [[ -n "${daily_backup}" ]] ; then
    backup ; fi
else
  fail "Invalid option selected" ; fi

final "Done"
