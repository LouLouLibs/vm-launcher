(* x509 1.0.6 API. Signing-request → certificate via
   X509.Signing_request.sign. We're self-signed for the CA + use the
   CA's signing-request flow with [is_ca = true] in basic constraints,
   then for leaves we use the CA cert as issuer + sign with the CA
   private key. *)

let one_year_from t =
  Ptime.add_span t (Ptime.Span.of_int_s (365 * 24 * 3600))
  |> Option.value ~default:t

let validity_window () =
  let now =
    match Ptime.of_float_s (Unix.gettimeofday ()) with
    | Some t -> t
    | None -> Ptime.epoch
  in
  (* Start 60s in the past — guards against minor clock skew between
     host (where we sign) and guest (where the agent validates). *)
  let from =
    Ptime.sub_span now (Ptime.Span.of_int_s 60)
    |> Option.value ~default:now
  in
  (from, one_year_from now)

let dn_of_cn cn =
  [ X509.Distinguished_name.(Relative_distinguished_name.singleton
      (CN cn))
  ]

type ca = {
  cert : X509.Certificate.t;
  key : X509.Private_key.t;
}

let generate_ca ?(common_name = "vm-launcher CA") () =
  let key = X509.Private_key.generate `P256 in
  let subject = dn_of_cn common_name in
  let req =
    match X509.Signing_request.create subject key with
    | Ok r -> r
    | Error (`Msg m) -> failwith ("CA signing request: " ^ m)
  in
  let valid_from, valid_until = validity_window () in
  let extensions =
    let open X509.Extension in
    empty
    |> add Basic_constraints (true, (true, None))
    |> add Key_usage
         (true, [ `Key_cert_sign; `CRL_sign; `Digital_signature ])
  in
  let cert =
    match
      X509.Signing_request.sign req ~valid_from ~valid_until
        ~extensions ~digest:`SHA256 key subject
    with
    | Ok c -> c
    | Error e ->
        failwith
          (Format.asprintf "CA sign: %a"
             X509.Validation.pp_signature_error e)
  in
  { cert; key }

let ca_cert_pem (ca : ca) = X509.Certificate.encode_pem ca.cert
let ca_key_pem (ca : ca) = X509.Private_key.encode_pem ca.key

let load_ca ~cert_pem ~key_pem =
  match X509.Certificate.decode_pem cert_pem with
  | Error (`Msg m) -> Error ("CA cert PEM: " ^ m)
  | Ok cert ->
      (match X509.Private_key.decode_pem key_pem with
       | Error (`Msg m) -> Error ("CA key PEM: " ^ m)
       | Ok key -> Ok { cert; key })

type leaf = {
  cert : X509.Certificate.t;
  key : X509.Private_key.t;
}

let generate_leaf ~(ca : ca) ~hostname =
  let key = X509.Private_key.generate `P256 in
  let subject = dn_of_cn hostname in
  let req =
    match X509.Signing_request.create subject key with
    | Ok r -> r
    | Error (`Msg m) -> failwith ("leaf signing request: " ^ m)
  in
  let valid_from, valid_until = validity_window () in
  let extensions =
    let open X509.Extension in
    let general_names =
      X509.General_name.singleton DNS [ hostname ]
    in
    empty
    |> add Subject_alt_name (false, general_names)
    |> add Basic_constraints (true, (false, None))
    |> add Key_usage
         (true,
          [ `Digital_signature; `Key_encipherment ])
    |> add Ext_key_usage (true, [ `Server_auth ])
  in
  let issuer = X509.Certificate.subject ca.cert in
  let cert =
    match
      X509.Signing_request.sign req ~valid_from ~valid_until
        ~extensions ~digest:`SHA256 ca.key issuer
    with
    | Ok c -> c
    | Error e ->
        failwith
          (Format.asprintf "leaf sign: %a"
             X509.Validation.pp_signature_error e)
  in
  { cert; key }

let leaf_cert l = l.cert
let leaf_key l = l.key

let leaf_cert_pem l = X509.Certificate.encode_pem l.cert
let leaf_key_pem l = X509.Private_key.encode_pem l.key
