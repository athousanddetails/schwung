# HiJack — running a Schwung synth on a Move track

HiJack is a per-slot switch: **slot N replaces Move's own engine on track N**,
while Move's sequencer, scales, arp and pads keep driving it. It is shim +
shadow UI only — no module changes, and it works with any sound generator.

Four independent switches. Tracks 1 and 3 can be hijacked while 2 and 4 keep
behaving normally.

## What it does

Turning HiJack on for a slot has three effects.

### 1. The slot stops following Move's track fader

Schwung normally mirrors Move's track fader onto the slot volume over D-Bus
(`shadow_dbus.c`, "D-Bus volume sync: slot N = …"), while a track button is
held. A hijacked slot is exempt from that sync.

That exemption is the whole trick. With the sync skipped, the user pulls Move's
track fader to −inf: **Move's own instrument goes silent, the track stays
unmuted so it keeps emitting notes, and the Schwung slot keeps playing at full
level.**

Muting the track instead would be simpler and does not work — muting a Move
track kills its MIDI as well as its audio, so the slot goes silent too. The
fader does not. That is why HiJack uses the fader.

### 2. Enabling it drives that fader down for you (one-shot)

Move exposes no way to set a track volume from outside: no D-Bus setter (only
`saveSongIfDirty` / `refreshCache` / `importSongBundleFile`), no web API
listening, and Move owns `Song.abl` in memory and overwrites external edits.

So the shim plays Move's own UI instead, through the `/schwung-midi-inject`
ring: hold the track button (CC 43−N — track CCs are reversed, CC43 = Track 1),
pump encoder detents down, release. Move makes the change itself, so it
persists and displays correctly.

Injected packets land in the shadow buffer Move reads, while the shim's own
long-press and knob detectors read the **hardware** buffer — so this cannot
trip Schwung's own shortcuts.

### 3. The volume encoder belongs to the slot

While a hijacked track's button is held, CC 79 is filtered out before Move sees
it and applied to the Schwung slot's volume instead, with an on-screen level
overlay. Move's track fader stays parked where the user left it.

## The state / gesture split — read before changing anything

`slot:hijack` (per-slot state) and `master_fx:hijack_zero` (the fader gesture)
are **separate params on purpose**.

An earlier build had one param do both: setting "which slot is hijacked" *was*
what performed the hold-pump-release. That meant every path which restored the
state performed the gesture. A boot with the state restored silently pumped 400
detents into Move; and because the release packet was pushed without checking
whether the ring accepted it, a dropped release left Move believing a track
button was still held — sticking its volume overlay on screen until reboot.

The contract now:

| Param | Direction | Meaning |
|---|---|---|
| `slot:hijack` | get/set | Per-slot flag. **Inert** — setting it never moves Move's fader. |
| `master_fx:hijack_zero` | set (action) | Value = slot index. Runs the fader gesture once. Ignored while a gesture is in flight. Reads back the phase. |
| `master_fx:hijack_active` | get | Slot whose volume gesture owns the OLED, or −1. Lets shadow_ui draw the overlay for the right slot. |

**Only a user toggle may write `hijack_zero`.** Every restore path — boot,
set change, chain-config load — writes `slot:hijack` and nothing else.

The pump is a small state machine in `shim_post_transfer` (HOLD → PUMP →
RELEASE). Every push is checked, so a full ring is a retry rather than a lost
packet; `HIJACK_ZERO_MAX_FRAMES` abandons a jammed pump and spends what is left
of the budget on the release; `HIJACK_ZERO_RELEASE_GRACE` bounds that retry so
a dead injection path does not spin every SPI frame forever.

`tests/host/test_hijack_per_slot_hooks.sh` pins this split.

## Persistence

The flag lives on `shadow_chain_slot_t.hijacked` and rides the ordinary
chain-config path, so it travels with the set:

- per-set `shadow_chain_config.json` — `"hijack": 0|1` per slot, written and
  read by both `shadow_set_pages.c` and `shadow_ui.js`
  (`saveChainConfigToDir` / `loadChainConfigFromDir`)
- global state file — `"slot_hijack": [0,0,0,0]` in `shadow_state.c`
- new sets are seeded with `"hijack": 0`

Loaders **always write** the flag rather than skipping when the key is absent.
A config saved before HiJack existed has no field, and skipping would leave the
previous set's slot still hijacked — the same trap the `receive_channel`
comment in `loadChainConfigFromDir` documents.

Writing it to the shim from JS (not from the shim itself) is deliberate: the
param handler and the SPI callback path ban file I/O (see
`docs/REALTIME_SAFETY.md`).

## What HiJack does not do

**It cannot avoid Move's per-track MIDI Out setting.** Schwung only dispatches
cable 2 of MIDI_OUT to chain slots, and cable 2 is populated only when the
track's MIDI Out is enabled. There is no safe way to set that from Schwung
(`tracks[N].midiOutputEndpoint` lives in `Song.abl`; reading is safe, writing is
not). So the user enables MIDI Out once per track, then HiJack handles the rest.

**Move's FX cannot process live Schwung audio.** Move's USB-C monitoring
self-oscillates on its own — it fed back while Schwung was sending pure silence,
with the USB-C controller unplugged. That is Move firmware, not Schwung.
*Recording* Schwung audio into Move works fine. Link Audio is not an input
route either: published `ME-N` channels are outputs for Link peers
(`link_audio.h`, "Live is requesting this channel").

**Turning HiJack off does not raise Move's fader again.** It only restores the
volume sync. Raising the track back is the user's call — and a second automatic
gesture is exactly the kind of hidden side effect this design removed.

## Where the code is

| Concern | File |
|---|---|
| Per-slot flag | `src/host/shadow_chain_types.h` (`hijacked`) |
| `slot:hijack` get/set, key delegation | `src/host/shadow_chain_mgmt.c` |
| Volume-sync exemption | `src/host/shadow_dbus.c` |
| Gesture, CC 79 redirect, OLED handoff | `src/schwung_shim.c` |
| Global / per-set persistence | `src/host/shadow_state.c`, `src/host/shadow_set_pages.c` |
| Settings rows, toggle, overlay | `src/shadow/shadow_ui.js`, `src/shadow/shadow_ui_slots.mjs` |

Note there are **two** near-identical slot settings lists — `CHAIN_SETTINGS_ITEMS`
in `shadow_ui.js` and `SLOT_SETTINGS` in `shadow_ui_slots.mjs` (legacy). Adding
a row to only one means it is missing from whichever screen the user is on.
