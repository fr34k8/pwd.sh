#!/usr/bin/env bash
# https://github.com/drduh/pwd.sh/blob/master/pwd.sh

#set -x  # uncomment to debug
set -o errtrace
set -o nounset
set -o pipefail

umask 077

export LC_ALL="C"

gpgBin="$(command -v gpg || command -v gpg2)"
gpgPath="${HOME}/.gnupg"
gpgConf="${gpgPath}/gpg.conf"

now="$(date +%s)"
today="$(date +%F)"

vers="v4"
name="$(basename "$0")"
app="${vers}-${name}"

backupFname="${app}.$(hostname).${today}.tar" # backup archive
backupStore="${PWDSH_BACKUP_NAME:=${backupFname}}"
backupDaily="${PWDSH_BACKUP_DAILY:=}" # daily archive on write

secretStore="${PWDSH_STORE:=${app}.secret}" # secretsdirectory
secretIndex="${PWDSH_INDEX:=${app}.index}"  # index file
secretPepper="${PWDSH_PEPPER:=}"            # optional pepper file

clipCmd="${PWDSH_CLIP_CMD:=xclip}"     # clipboard, 'pbcopy' on macOS
clipArg="${PWDSH_CLIP_ARG:=}"          # args to pass to clip command
clipOut="${PWDSH_CLIP_OUT:=clipboard}" # cb type, 'screen' for stdout
clipSec="${PWDSH_CLIP_SEC:=10}"        # seconds to clear cb/screen

optCopyBeforeWrite="${PWDSH_COPY:=}"  # copy secret before write
optDictionaryWords="${PWDSH_DICT:=/usr/share/dict/words}"
optSecretEchoChars="${PWDSH_ECHO:=*}" # echo "*" when typing passwords
optSecretLength="${PWDSH_LEN:=20}"    # default secret length
optPublicComment="${PWDSH_COMMENT:=}" # public/plaintext file comment
optSecretChars="${PWDSH_CHAR:='A-Za-z0-9!@#$%^&*()_+'}"

trap cleanup EXIT INT TERM
cleanup() {
  # "Lock" files on trapped exits.

  ret=$?
  chmod -R 0000 "${secretPepper}" \
                "${secretStore}" \
                "${secretIndex}" 2>/dev/null
  exit ${ret}
}

timestamp() {
  # Format current date and time.

  date +"%A %b %d %H:%M:%S"
}

log() {
  # Print formatted and timestamped events.

  local color="${1}"
  shift

  tput setaf "${color}"
  printf '(%s) %s\n' "$(timestamp)" "$*"
  tput sgr0
}

fail()  { log 1 "$@"; exit 1; }
final() { log 2 "$@"; exit 0; }
warn()  { log 3 "$@"; }

generatePepper() {
  # Generate, display and save "pepper" secret value.

  warn "created ${secretPepper} - copy to secure storage:"
  printf "%s\n" \
    "$(tr -dc 'A-Y2-9' < /dev/urandom | tr -d "IOS5UB" | \
    fold -w 6 | paste -sd - - | head -c 27)" | \
  tee "${secretPepper}" || fail "Failed writing ${secretPepper}"
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
      prompt="${optSecretEchoChars}"
      password+="${char}"
    fi
  done

  printf "\n"
}

decrypt() {
  # Decrypt with GPG.

  printf "%s" "${1}${pepperSecret}" | \
    ${gpgBin} --armor --batch \
    --decrypt --no-symkey-cache \
    --passphrase-fd 0 \
    "${2}" 2>/dev/null
}

encrypt() {
  # Encrypt with GPG.

  ${gpgBin} --armor --batch --yes \
    --symmetric \
    --comment "${optPublicComment}" \
    --passphrase-fd 3 \
    --output "${2}" "${3}" 3< \
    <(printf "%s" "${1}${pepperSecret}") 2>/dev/null
}

readSecret() {
  # Decrypt to read a secret.

  verifyIndex

  while [[ -z "${username}" ]] ; do
    if [[ -z "${2+x}" ]] ; then read -r -p \
      "Username: " username
    else username="${2}" ; fi
  done

  promptPassword "Password to access ${secretIndex}: "

  spath=$(decrypt "${password}" "${secretIndex}" | \
    grep -F "${username}" | tail -1 | cut -d ":" -f 2) || \
      fail "Secret not available"

  revealPass <(decrypt "${password}" "${spath}") || \
    fail "Failed to decrypt ${spath}"
}

generateSecret() {
  # Generate a secret from urandom.

  if [[ -z "${3+x}" ]] ; then read -r -p \
    "Secret length (Enter for ${optSecretLength}): " length
  else length="${3}" ; fi

  if [[ "${length}" =~ ^[0-9]+$ ]] ; then
    optSecretLength="${length}" ; fi

  tr -dc "${optSecretChars}" < /dev/urandom | \
    head -c "${optSecretLength}"
}

generateUsername() {
  # Generate a random username.

  countDigits=3
  countWords=2

  words=$(awk '
    length > 2 && length < 12 &&
    index($0, "'"'"'") == 0 { print tolower($0) }' \
    ${optDictionaryWords} | sort -R | head -n ${countWords} | \
    tr '\n' '-' | tr -cd 'a-z0-9-\n'
  )
  digits=$(tr -dc '0-9' < /dev/urandom | head -c ${countDigits})
  printf '%s%s\n' "${words}" "${digits}"
}

writeSecret() {
  # Write a secret and update the index.

  sname="$(tr -dc 'a-z' < /dev/urandom | head -c 10)"
  spath="${secretStore%/}/${app}.${sname}"

  if [[ -n "${optCopyBeforeWrite}" ]] ; then
    revealPass <(printf '%s' "${userpass}") ; fi

  promptPassword "Password to access ${secretIndex}: "

  printf '%s\n' "${userpass}" | \
    encrypt "${password}" "${spath}" - || \
      fail "Failed saving ${spath}"

  { if [[ -s "${secretIndex}" ]]; then
      decrypt "${password}" "${secretIndex}" || return
    fi
    printf "%s@%s:%s\n" "${username}" "${now}" "${spath}"
  } | encrypt "${password}" "${secretIndex}.${now}" -

  if ! mv "${secretIndex}.${now}" "${secretIndex}"; then
    fail "Failed saving ${secretIndex}.${now}" ; fi
}

listSecrets() {
  # Decrypt the index to list secrets.

  verifyIndex
  promptPassword "Password to access ${1}: "
  decrypt "${password}" "${1}" || \
    fail "${1} not available"
}

backup() {
  # Archive index, store and GPG configuration.

  gpgConfCopy="${app}.gpg.conf"

  if [[ -s "${backupStore}" ]] ; then
    fail "Skipping archive - '${backupStore}' exists" ; fi

  if [[ ! -s "${secretIndex}" &&
        ! -d "${secretStore}" ]] ; then
    fail "Nothing to archive" ; fi

  cp "${gpgConf}" "${gpgConfCopy}"
  tar cvf "${backupStore}" \
    "${secretStore}" "${secretIndex}" \
    "${BASH_SOURCE}" "${gpgConfCopy}" ||
    fail "Failed archiving to ${backupStore}"

  final "Archived ${backupStore}"
}

revealPass() {
  # Reveal secret to clipboard or stdout and
  # clear after timeout.

  if [[ "${clipOut}" = "screen" ]] ; then
    printf '\n%s\n' "$(cat "${1}")"
  else ${clipCmd} < "${1}" ; fi

  printf "\n"
  while [[ "${clipSec}" -gt 0 ]] ; do
    printf "\r\033[KSecret on %s! Clearing in %.d" \
      "${clipOut}" "$((clipSec--))" ; sleep 1
  done

  printf "\r\033[KClearing password from %s ..." \
    "${clipOut}"

  if [[ "${clipOut}" = "screen" ]] ; then
    clear
  else printf "\n" ; printf "" | ${clipCmd} ; fi
}

newSecret() {
  # Prompt for username and password.

  if [[ -z "${2+x}" ]] ; then read -r -p \
    "Username (Enter to generate): " username
  else username="${2}" ; fi

  if [[ -z "${username}" ]] ; then
    username=$(generateUsername "$@") ; fi

  if [[ -z "${3+x}" ]] ; then
    promptPassword "Secret for '${username}' (Enter to generate): "
    userpass="${password}" ; fi

  if [[ -z "${password}" ]] ; then
    userpass=$(generateSecret "$@") ; fi
}

verifyIndex() {
  # Verify the index file exists and is non-empty.

  [[ -s "${secretIndex}" ]] || fail "${secretIndex} not found"
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
  [[ -n "${gpgBin}" ]]  || fail "GnuPG binary not available"
  [[ -s "${gpgConf}" ]] || fail "GnuPG config not available"
}

initStorage() {
  if [[ ! -d "${secretStore}" ]] ; then
    mkdir -p "${secretStore}" ; fi
  chmod -R 0700 "${secretPepper}" \
                "${secretIndex}" \
                "${secretStore}" 2>/dev/null
}

initPepper() {
  pepperSecret=""

  if [[ -n "${secretPepper}" && \
      ! -s "${secretPepper}" ]] ; then
    generatePepper ; fi

  if [[ -s "${secretPepper}" ]] ; then
    pepperSecret="$(cat "${secretPepper}")" ; fi
}

initClipboard() {
  if [[ -z "$(command -v "${clipCmd}")" ]] ; then
    clipOut="screen"
    warn "Clipboard not available -" \
         "secrets will appear on screen/stdout!"
  elif [[ -n "${clipArg}" ]] ; then
    clipCmd+=" ${clipArg}" ; fi
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
  listSecrets "${secretIndex}"
  final "Listed ${secretIndex}"
elif [[ "${activity}" =~ ^([wW])$ ]] ; then
  newSecret "$@"
  writeSecret
  if [[ -n "${backupDaily}" ]] ; then
    backup ; fi
else
  fail "Invalid option selected" ; fi

final "Done"
