# vmgui wire protocol, version 1

The window protocol for guests without Wayland (Windows 11, macOS). Linux guests use
waypipe instead. One guest agent holds one vsock connection to host CID 2, port 20000 + the
guest's CID. vmgui-host checks the peer CID and hands the stream to `vmgui-wire`. That's a
confined, unprivileged Wayland client in the VM's `scroll-vm` security context, and it
draws every window as a plain xdg toplevel from shm buffers. There's no GPU path, no
clipboard and no file transfer.

The design follows Qubes' GUI protocol: fixed little-endian structs, raw pixels, no
compression and no parsing beyond lengths. The host rejects anything unexpected by
closing the connection, and all of that VM's windows go with it.

## Framing

Every message is a 12-byte header, then `length` bytes of payload.

| Offset | Type | Field |
|---|---|---|
| 0 | u16 | `type` |
| 2 | u16 | `flags`, must be 0 |
| 4 | u32 | `window`: guest-chosen id, nonzero; 0 only for `HELLO` |
| 8 | u32 | `length`: payload bytes, at most 16 MiB + 16 |

## Guest to host

| Type | Name | Payload | Rules |
|---|---|---|---|
| 0x01 | `HELLO` | u32 magic `0x57474d56` ("VMGW"), u32 version (1) | First message, exactly once |
| 0x02 | `CREATE` | u32 width, u32 height | New toplevel. Id must be unused. At most 64 windows |
| 0x03 | `DESTROY` | none | |
| 0x04 | `TITLE` | UTF-8, at most 512 bytes | Invalid UTF-8 is replaced and control characters are dropped. The host prefixes `[vm]` |
| 0x05 | `RESIZE` | u32 width, u32 height | Guest-side size change. Contents are black until damaged |
| 0x06 | `DAMAGE` | u32 x, y, w, h; then w·h·4 bytes | Pixels are XRGB8888 (bytes B, G, R, X), rows top-down, no padding. The rectangle must lie inside the window |
| 0x07 | `COMMIT` | none | Present everything damaged since the last commit |

Sizes are 1..4096 per side. The total pixel memory across all windows is capped at
256 MiB per connection.

## Host to guest

| Type | Name | Payload | Meaning |
|---|---|---|---|
| 0x81 | `CONFIGURE` | u32 width, u32 height | The compositor wants this size (0 = guest's choice) |
| 0x82 | `CLOSE` | none | The user closed the window |
| 0x83 | `FOCUS` | u32 focused (0 or 1) | Keyboard focus in or out |
| 0x84 | `MOTION` | i32 x, i32 y | Pointer at window-local pixels |
| 0x85 | `BUTTON` | u32 button (Linux `BTN_*`), u32 pressed | |
| 0x86 | `AXIS` | u32 axis (0 = vertical, 1 = horizontal), i32 value (1/256 px) | Scroll |
| 0x87 | `KEY` | u32 keycode (Linux evdev), u32 pressed | The guest maps evdev to its own codes |
| 0x88 | `LEAVE` | none | Pointer left the window |

The guest ignores host messages for windows it has destroyed. Keyboard input goes only to
the window the compositor has focused, which is the same rule as for any Wayland client.
