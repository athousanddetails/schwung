#!/usr/bin/env bash
set -euo pipefail

# Pins HiJack's structure: a per-slot flag that replaces Move's engine on the
# matching track, and a fader gesture that is a SEPARATE one-shot action.
#
# An earlier build bound the gesture to the state param — setting "which slot is
# hijacked" was what held the track button and pumped 400 encoder detents into
# Move. Every path that restored the state therefore replayed the gesture (a
# boot silently re-zeroed the fader), and a dropped release packet left Move
# believing a track button was still held, sticking its volume overlay on screen
# until reboot. These pins exist so that split cannot quietly collapse again.

types_file="src/host/shadow_chain_types.h"
mgmt_file="src/host/shadow_chain_mgmt.c"
dbus_file="src/host/shadow_dbus.c"
shim_file="src/schwung_shim.c"
state_file="src/host/shadow_state.c"
sets_file="src/host/shadow_set_pages.c"
ui_file="src/shadow/shadow_ui.js"
slots_file="src/shadow/shadow_ui_slots.mjs"

for f in "$types_file" "$mgmt_file" "$dbus_file" "$shim_file" "$state_file" \
         "$sets_file" "$ui_file" "$slots_file"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f not found (run from repo root)" >&2
    exit 1
  fi
done

# --- per slot, not one global index -----------------------------------------

if ! rg -q '^\s*int hijacked;' "$types_file"; then
  echo "FAIL: HiJack state belongs on shadow_chain_slot_t as 'hijacked'," >&2
  echo "      so all four tracks can be switched independently" >&2
  exit 1
fi

# A lone hijack_slot int is exactly the shape this redesign removed.
if rg -q 'hijack_slot[^_]' "$shim_file" "$mgmt_file" "$dbus_file" "$ui_file" "$slots_file"; then
  echo "FAIL: a single global hijack_slot index is back — HiJack is per slot" >&2
  exit 1
fi

for pin in 'strcmp\(key, "slot:hijack"\) == 0'; do
  if [[ "$(rg -c "$pin" "$mgmt_file")" != "2" ]]; then
    echo "FAIL: slot:hijack needs both a set and a get handler in $mgmt_file" >&2
    exit 1
  fi
done

# --- the state param must be inert -------------------------------------------

# The set handler's body must not reach for the injection ring or the gesture.
# Comment lines are stripped — the prose there names hijack_zero on purpose.
set_body="$(awk '/if \(strcmp\(key, "slot:hijack"\) == 0\) \{/ {f=1}
                 f {print}
                 f && /^    \}$/ {exit}' "$mgmt_file" \
            | grep -vE '^\s*(/?\*|//)')"
if [[ "$(grep -c . <<<"$set_body")" -lt 3 ]]; then
  echo "FAIL: could not read the slot:hijack set handler — this pin is only" >&2
  echo "      meaningful if it actually sees the body" >&2
  exit 1
fi
if rg -q 'inject|hijack_zero|track_cc|detent' <<<"$set_body"; then
  echo "FAIL: setting slot:hijack must NOT perform the fader gesture — that is" >&2
  echo "      what made every state restore re-pump detents into Move" >&2
  exit 1
fi

# --- the gesture is a separate one-shot action -------------------------------

if ! rg -q 'strcmp\(fx_key, "hijack_zero"\) == 0' "$shim_file"; then
  echo "FAIL: expected master_fx:hijack_zero as the standalone fader action" >&2
  exit 1
fi

# Only a user toggle may fire it. The persistence loaders restore slot:hijack
# and nothing else; shadow_chain_mgmt.c may name it once, to route the key.
if rg -q 'hijack_zero' "$state_file" "$sets_file"; then
  echo "FAIL: hijack_zero must not appear on a state restore path" >&2
  exit 1
fi
if ! rg -q 'strcmp\(param_key, "hijack_zero"\) == 0' "$mgmt_file"; then
  echo "FAIL: master_fx:hijack_zero must be delegated to the shim's special" >&2
  echo "      param handler, or the key never reaches the gesture" >&2
  exit 1
fi

for f in "$ui_file" "$slots_file"; do
  if [[ "$(rg -c '\(slot, "master_fx:hijack_zero", String\(slot\)\)' "$f")" != "1" ]]; then
    echo "FAIL: $f should fire master_fx:hijack_zero exactly once, from the" >&2
    echo "      HiJack enable toggle" >&2
    exit 1
  fi
  # The toggle commits three params over the single shadow_param SHM slot.
  # Non-blocking writes clobber each other: measured on device, the
  # hijack_zero write landed on about one toggle in six.
  if rg -q 'setSlotParam\(slot, "master_fx:hijack_zero"' "$f"; then
    echo "FAIL: $f must commit the HiJack toggle with BLOCKING writes, or the" >&2
    echo "      gesture request is clobbered before the shim drains it" >&2
    exit 1
  fi
done

# A second request while one is in flight would interleave two holds and leave
# neither release matching.
if ! rg -q 'hijack_zero_phase == HIJACK_ZERO_IDLE' "$shim_file"; then
  echo "FAIL: hijack_zero must ignore a request while a gesture is in flight" >&2
  exit 1
fi

# --- the release is guaranteed ----------------------------------------------

pump_body="$(sed -n '/HiJack auto-zero pump/,/^    \/\* Timing:/p' "$shim_file")"
if [[ "$(grep -c . <<<"$pump_body")" -lt 20 ]]; then
  echo "FAIL: could not read the auto-zero pump — this pin is only meaningful" >&2
  echo "      if it actually sees the body" >&2
  exit 1
fi

if ! rg -q 'if \(shadow_midi_inject_push\(shadow_midi_inject_shm, rel\) == 0\) \{' <<<"$pump_body"; then
  echo "FAIL: the release push must be checked and retried — an unchecked push" >&2
  echo "      into a full ring loses the release and sticks Move's overlay" >&2
  exit 1
fi

# shadow_midi_inject_push returns 0 on SUCCESS, -1 on ring-full. A truthiness
# test therefore reads success as failure. That inversion shipped once: the HOLD
# packet was enqueued on every frame of the budget while the phase never
# advanced, so Move got a stream of button-holds and no encoder detents at all.
if rg -q 'if \(!?shadow_midi_inject_push\([^)]*\)\)' <<<"$pump_body"; then
  echo "FAIL: compare shadow_midi_inject_push against 0 explicitly — it returns" >&2
  echo "      0 on SUCCESS, so a bare truthiness test inverts the check" >&2
  exit 1
fi

if ! rg -q 'HIJACK_ZERO_MAX_FRAMES' <<<"$pump_body"; then
  echo "FAIL: the pump needs a frame timeout that falls through to the release" >&2
  exit 1
fi

if ! rg -q 'HIJACK_ZERO_RELEASE_GRACE' <<<"$pump_body"; then
  echo "FAIL: the release retry needs its own bound, or a dead injection path" >&2
  echo "      spins every SPI frame forever" >&2
  exit 1
fi

# shadow_midi_drain_injected() places at most ONE packet per frame (it writes
# only at MIDI_IN offset 0 and bails past any pre-existing event), and refuses
# to drain at all while hardware MIDI is present. Pushing faster than that just
# overflows the 64-slot ring — measured 2026-08-15, a 6-per-frame pump never got
# Move to -inf because every push after the first ~64 failed.
if ! rg -q '#define HIJACK_ZERO_PER_FRAME  1$' "$shim_file"; then
  echo "FAIL: the pump must push at most one packet per frame — the drain" >&2
  echo "      cannot place more, so anything faster only overflows the ring" >&2
  exit 1
fi

# --- exemption and knob redirect key off the held track ----------------------

if ! rg -q 'host\.chain_slots\[held\]\.hijacked' "$dbus_file"; then
  echo "FAIL: the D-Bus volume-sync exemption must ask whether THIS slot is" >&2
  echo "      hijacked, using the held track index" >&2
  exit 1
fi

if ! rg -q 'hijack_slot_is_on\(shadow_held_track\)' "$shim_file"; then
  echo "FAIL: the CC 79 redirect must match the held track against its own slot" >&2
  exit 1
fi

# shadow_ui cannot tell which slot a CC 79 belongs to on its own.
if ! rg -q 'strcmp\(fx_key, "hijack_active"\) == 0' "$shim_file"; then
  echo "FAIL: expected master_fx:hijack_active so the overlay knows its slot" >&2
  exit 1
fi

if ! rg -q 'master_fx:hijack_active' "$ui_file"; then
  echo "FAIL: the volume overlay should read master_fx:hijack_active" >&2
  exit 1
fi

# --- persistence rides the chain config, not a side file ---------------------

if rg -q 'hijack_slot\.txt' "$ui_file"; then
  echo "FAIL: HiJack must persist through the chain config, not a flat file" >&2
  exit 1
fi

if [[ "$(rg -c 'slot_hijack' "$state_file")" -lt 2 ]]; then
  echo "FAIL: shadow_chain_config.json should both save and load slot_hijack" >&2
  exit 1
fi

if [[ "$(rg -c '\\"hijack\\": ' "$sets_file")" -lt 2 ]]; then
  echo "FAIL: the per-set chain config must both write and seed a hijack field" >&2
  exit 1
fi

# Skipping the write when the field is absent leaves the previous set's flag
# standing — the same class of bug the receive_channel comment documents.
if ! rg -q 'host\.chain_slots\[i\]\.hijacked = 0;' "$sets_file"; then
  echo "FAIL: shadow_load_config_from_dir must clear hijacked before parsing," >&2
  echo "      or a pre-HiJack config leaves the previous set's track hijacked" >&2
  exit 1
fi

if ! rg -q 'setSlotParamWithTimeout\(i, "slot:hijack"' "$ui_file"; then
  echo "FAIL: loadChainConfigFromDir must ALWAYS write slot:hijack" >&2
  exit 1
fi

# --- both settings screens carry the row -------------------------------------

for f in "$ui_file" "$slots_file"; do
  if ! rg -q '\{ key: "hijack", label: "HiJack"' "$f"; then
    echo "FAIL: $f is missing the HiJack row — there are two near-identical" >&2
    echo "      slot settings lists and the user may be looking at either" >&2
    exit 1
  fi
done

echo "PASS: HiJack is per-slot, its fader gesture is a separate guarded one-shot"
