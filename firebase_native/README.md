# firebase_native — deferred (pure-ArkTS transport ships)

This directory is a placeholder. The published OHPM package is
transport-agnostic and runs on `TlsSocketTransport` (pure ArkTS over
`@ohos.net.socket.TLSSocket`, zero native code) on any NEXT device.

The optional NAPI C++ TLS-socket bridge (`NapiBridgeTransport` <->
`FcmNativeBridge`: `connect/host/port`, `sendBytes`, `setOnMessage`
JSON events `{kind,id,payload_b64,decoded}`) is not compiled into the
HAP by default. To add it later: implement the bridge under
`firebase_native/src/` (socket + OpenSSL verify + protobuf decode +
mcs→JSON), wire it with a `.gni`/CMake target excluded from the OHPM
package, and inject it via `new NapiBridgeTransport(bridge)`.
