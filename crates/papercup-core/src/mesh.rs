// SPDX-License-Identifier: GPL-3.0-or-later
//
// WireGuard helpers for the Papercup mesh integration.
//
// The phone holds its own X25519 private key (Curve25519) and submits
// the matching public key when pairing. The Defguard mesh broker
// returns the peer endpoint, allowed IPs, MTU, and the address it has
// assigned to this device. We compose those into a wg-quick INI
// suitable for `com.wireguard.android.config.Config::parse` (Android)
// or `WireGuardKit` (iOS).

use base64::Engine as _;
use rand_core::OsRng;

#[derive(Debug, Clone)]
pub struct WgKeyPair {
    pub private_key_b64: String,
    pub public_key_b64: String,
}

/// Generate a fresh X25519 keypair. Both halves are returned base64-
/// encoded — the format every WireGuard implementation already speaks.
pub fn generate_wg_keypair() -> WgKeyPair {
    let secret = x25519_dalek::StaticSecret::random_from_rng(OsRng);
    let public = x25519_dalek::PublicKey::from(&secret);
    let b64 = base64::engine::general_purpose::STANDARD;
    WgKeyPair {
        private_key_b64: b64.encode(secret.to_bytes()),
        public_key_b64: b64.encode(public.to_bytes()),
    }
}

#[derive(Debug, Clone)]
pub struct MeshSpec {
    pub peer_public_key_b64: String,
    pub peer_endpoint: String,
    pub allowed_ips: Vec<String>,
    pub assigned_ip: String,
    pub mtu: u32,
}

/// Translate a `MeshSpec` (broker-assigned) + the phone's stored
/// private key into a wg-quick INI string. Suitable for both
/// `Config.parse(InputStream)` on Android and `tunnelConfiguration`
/// on iOS WireGuardKit.
pub fn to_wg_quick(private_key_b64: &str, spec: &MeshSpec) -> String {
    let allowed = if spec.allowed_ips.is_empty() {
        "0.0.0.0/0, ::/0".to_string()
    } else {
        spec.allowed_ips.join(", ")
    };
    format!(
        "[Interface]\n\
         PrivateKey = {priv}\n\
         Address = {addr}\n\
         MTU = {mtu}\n\
         \n\
         [Peer]\n\
         PublicKey = {peer}\n\
         AllowedIPs = {allowed}\n\
         Endpoint = {endpoint}\n\
         PersistentKeepalive = 25\n",
        priv = private_key_b64,
        addr = spec.assigned_ip,
        mtu = spec.mtu,
        peer = spec.peer_public_key_b64,
        allowed = allowed,
        endpoint = spec.peer_endpoint,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keypair_round_trip_lengths() {
        let kp = generate_wg_keypair();
        let b64 = base64::engine::general_purpose::STANDARD;
        assert_eq!(b64.decode(&kp.private_key_b64).unwrap().len(), 32);
        assert_eq!(b64.decode(&kp.public_key_b64).unwrap().len(), 32);
    }

    #[test]
    fn wg_quick_has_required_sections() {
        let spec = MeshSpec {
            peer_public_key_b64: "PEER123".into(),
            peer_endpoint: "10.0.0.1:51820".into(),
            allowed_ips: vec!["10.10.0.0/16".into()],
            assigned_ip: "10.10.0.5/32".into(),
            mtu: 1380,
        };
        let conf = to_wg_quick("PRIV", &spec);
        assert!(conf.contains("[Interface]"));
        assert!(conf.contains("[Peer]"));
        assert!(conf.contains("PrivateKey = PRIV"));
        assert!(conf.contains("PublicKey = PEER123"));
        assert!(conf.contains("Endpoint = 10.0.0.1:51820"));
        assert!(conf.contains("Address = 10.10.0.5/32"));
        assert!(conf.contains("MTU = 1380"));
    }
}
