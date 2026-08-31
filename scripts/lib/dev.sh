# Shared script setup. Source after cd-ing to the repo root.
#
# Load the local dev env (.envrc) if present, then apply the single app-level
# save-directory override, G4RECOMP_SAVE_DIR, onto the variable LÖVE/PhysFS reads
# for its save-dir base. This is the one seam a future portable mode will reuse;
# when G4RECOMP_SAVE_DIR is unset, LÖVE uses the OS default per-user location.
[ -f .envrc ] && source .envrc

if [ -n "${G4RECOMP_SAVE_DIR:-}" ]; then
  case "$(uname -s)" in
    # Linux/BSD: PhysFS derives the save-dir base from XDG_DATA_HOME.
    Linux|*BSD) export XDG_DATA_HOME="$G4RECOMP_SAVE_DIR" ;;
    # macOS/Windows use fixed appdata roots; wire their overrides in when
    # portable mode lands. For now this keeps dev on those platforms explicit.
    *) export XDG_DATA_HOME="$G4RECOMP_SAVE_DIR" ;;
  esac
fi
