(** Self-signed CA + on-demand leaf cert generation for the in-VM
    egress proxy's MITM path.

    The CA is generated fresh per proxy startup (per VM session): the
    private key never leaves the proxy's process memory, the public
    cert is exported via PEM so the guest's trust store can install it
    via [security.pki.certificateFiles] before the proxy boots. Per-VM
    rotation bounds the blast radius of any key leak to one session.

    Leaf certs are generated lazily, one per target hostname the proxy
    needs to MITM. Standard clients honor [subjectAltName] for the
    hostname match; CN is set to the hostname too for older client
    compat. *)

type ca
(** A generated CA — opaque to callers; contains the X509 cert + the
    private key it was signed with. Keep the value in scope for the
    lifetime of the proxy; leaking it via PEM is fine but only the
    cert PEM should be exposed outside the proxy process. *)

val generate_ca : ?common_name:string -> unit -> ca
(** Generate a fresh self-signed CA. [common_name] defaults to
    ["vm-launcher CA"]. Uses an EC P-256 key (smaller + faster than
    RSA, universally supported). Requires the mirage-crypto RNG to
    have been initialised — callers should invoke
    [Mirage_crypto_rng_unix.use_default ()] once at program start. *)

val ca_cert_pem : ca -> string
(** Serialize the CA certificate as PEM. Safe to write to a file the
    guest's trust store reads. *)

val ca_key_pem : ca -> string
(** Serialize the CA private key as PEM. SENSITIVE — should never
    leave the proxy's address space in production. Exposed for tests
    + for the cases where the launcher needs to persist the key to a
    egressproxy-owned file before exec'ing the proxy. *)

val load_ca : cert_pem:string -> key_pem:string -> (ca, string) result
(** Decode a CA cert + private key from PEM. Used by the proxy when
    the launcher generates the CA out-of-band and hands the paths in
    via [--proxy-ca-cert]/[--proxy-ca-key]. Error message is a free-
    form one-line diagnostic suitable for logging. *)

type leaf
(** A leaf cert + key signed by the CA, scoped to a single hostname.
    The cert chain to present in TLS is just [leaf_cert leaf]; clients
    that need the CA in the chain can fetch [ca_cert_pem] separately. *)

val generate_leaf : ca:ca -> hostname:string -> leaf
(** Mint a leaf cert for [hostname]. The hostname is set as the
    subject CN and as a dNSName in subjectAltName. Validity matches
    the CA's window. EC P-256 key. *)

val leaf_cert : leaf -> X509.Certificate.t
val leaf_key : leaf -> X509.Private_key.t

val leaf_cert_pem : leaf -> string
val leaf_key_pem : leaf -> string
(** PEM serialization, primarily for tests. *)
