#!/bin/zsh

# Shared by the macOS installer and its shell-only regression tests.
# The caller is responsible for enabling strict shell options.

wristremote_canonical_app_path() {
  local candidate="$1"

  [[ -n "$candidate" && "$candidate" == /* && "$candidate" == *.app ]] || return 64
  [[ "$candidate" != *$'\n'* && "$candidate" != *$'\r'* ]] || return 64
  [[ ! -L "$candidate" ]] || return 65
  print -r -- "${candidate:A}"
}

# Selects a code-signing identity without writing certificate metadata to disk or
# echoing it to the terminal. The selected value exists only in this shell and is
# consumed directly by codesign.
typeset -g WRISTREMOTE_SELECTED_CODESIGN_IDENTITY=''
typeset -g WRISTREMOTE_CODESIGN_SELECTION=''

wristremote_choose_codesign_identity() {
  local explicit_identity="${1-}"
  local identity_snapshot="${2-}"
  local line hash common_name index explicit_upper
  local -a identity_hashes identity_names development_hashes matched_hashes
  local -A seen_development seen_matches
  local unparsed_development_identity=0

  WRISTREMOTE_SELECTED_CODESIGN_IDENTITY=''
  WRISTREMOTE_CODESIGN_SELECTION=''

  [[ "$explicit_identity" != *$'\n'* && "$explicit_identity" != *$'\r'* ]] || {
    print -u2 -- "WRIST_CODESIGN_IDENTITY must identify one valid local signing identity."
    return 64
  }
  [[ "$explicit_identity" != '-' ]] || {
    print -u2 -- "WRIST_CODESIGN_IDENTITY cannot force ad-hoc signing. Unset it to use safe automatic selection."
    return 64
  }

  while IFS= read -r line; do
    if [[ "$line" =~ '^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"([^"]+)"' ]]; then
      hash="${match[1]:u}"
      common_name="$match[2]"
      if [[ "$common_name" == 'Apple Development:'* && -z "${seen_development[$hash]-}" ]]; then
        identity_hashes+=("$hash")
        identity_names+=("$common_name")
        development_hashes+=("$hash")
        seen_development[$hash]=1
      fi
    elif [[ "$line" == *'"Apple Development:'* ]]; then
      unparsed_development_identity=1
    fi
  done <<< "$identity_snapshot"

  (( unparsed_development_identity == 0 )) || {
    print -u2 -- "Could not safely parse an available Apple Development identity; refusing to guess or use ad-hoc signing."
    return 78
  }

  if [[ -n "$explicit_identity" ]]; then
    explicit_upper="${explicit_identity:u}"
    for (( index = 1; index <= ${#identity_hashes}; index++ )); do
      hash="${identity_hashes[$index]}"
      common_name="${identity_names[$index]}"
      if [[ "$explicit_upper" == "$hash" || "$explicit_identity" == "$common_name" ]]; then
        if [[ -z "${seen_matches[$hash]-}" ]]; then
          matched_hashes+=("$hash")
          seen_matches[$hash]=1
        fi
      fi
    done

    (( ${#matched_hashes} == 1 )) || {
      print -u2 -- "WRIST_CODESIGN_IDENTITY must match exactly one valid local Apple Development identity."
      return 78
    }
    WRISTREMOTE_SELECTED_CODESIGN_IDENTITY="${matched_hashes[1]}"
    WRISTREMOTE_CODESIGN_SELECTION='explicit'
    return 0
  fi

  case "${#development_hashes}" in
    0)
      WRISTREMOTE_SELECTED_CODESIGN_IDENTITY='-'
      WRISTREMOTE_CODESIGN_SELECTION='ad-hoc'
      ;;
    1)
      WRISTREMOTE_SELECTED_CODESIGN_IDENTITY="${development_hashes[1]}"
      WRISTREMOTE_CODESIGN_SELECTION='apple-development'
      ;;
    *)
      print -u2 -- "Multiple valid Apple Development identities are available; set WRIST_CODESIGN_IDENTITY explicitly for this invocation."
      return 78
      ;;
  esac
}

wristremote_select_codesign_identity() {
  local explicit_identity="${1-}"
  local identity_snapshot=''

  if ! identity_snapshot="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)"; then
    print -u2 -- "Could not inspect local code-signing identities; refusing to guess or fall back to ad-hoc signing."
    return 1
  fi
  wristremote_choose_codesign_identity "$explicit_identity" "$identity_snapshot"
}

wristremote_running_bridge_snapshot() {
  /bin/ps -axo pid=,comm=
}

wristremote_resolve_bridge_executable() {
  local pid="$1"
  local reported_path="$2"
  local resolved_path=''

  if [[ "$reported_path" == /* ]]; then
    print -r -- "${reported_path:A}"
    return 0
  fi

  resolved_path="$({
    /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null || true
  } | /usr/bin/sed -nE 's/^n(\/.*\/WristRemoteBridge)$/\1/p' | /usr/bin/head -n 1)"
  [[ -n "$resolved_path" ]] || return 1
  print -r -- "${resolved_path:A}"
}

wristremote_assert_install_target_idle() {
  local target_app="$1"
  local supplied_snapshot="${2-}"
  local target_executable="${target_app:A}/Contents/MacOS/WristRemoteBridge"
  local snapshot line pid reported_path executable_path
  local exact_target_running=0
  local conflicting_target_running=0
  local unresolved_process=0

  if (( $# >= 2 )); then
    snapshot="$supplied_snapshot"
  else
    snapshot="$(wristremote_running_bridge_snapshot)"
  fi

  while IFS= read -r line; do
    [[ "$line" =~ '^[[:space:]]*([0-9]+)[[:space:]]+(.+)$' ]] || continue
    pid="$match[1]"
    reported_path="$match[2]"
    [[ "${reported_path:t}" == WristRemoteBridge ]] || continue

    if ! executable_path="$(wristremote_resolve_bridge_executable "$pid" "$reported_path")"; then
      print -u2 -- "Refusing installation: running WristRemoteBridge process $pid could not be resolved to an exact app path."
      unresolved_process=1
      continue
    fi

    if [[ "$executable_path" == "$target_executable" ]]; then
      print -u2 -- "Refusing installation: the target app is still running ($executable_path). Quit it normally, then retry."
      exact_target_running=1
    else
      print -u2 -- "Refusing installation: another WristRemoteBridge is running from $executable_path"
      print -u2 -- "Requested target: $target_app"
      print -u2 -- "Quit the other Bridge or explicitly select that exact app with --target-app after verifying its Bundle identifier."
      conflicting_target_running=1
    fi
  done <<< "$snapshot"

  (( exact_target_running == 0 && conflicting_target_running == 0 && unresolved_process == 0 ))
}
