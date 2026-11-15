package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Signed indexes.
//
// Every index this repo publishes — each engine's mirror index.yaml and the
// add-on indexes — is signed the way the module registry signs a module index
// (doze-sdk modindex, doze-registry scripts/lib.mjs):
//
//   - each artifact carries `sig`: base64 ed25519 over its lowercase-hex
//     sha256 string (the module scheme's per-artifact gate, unchanged);
//   - the document carries `signature`: base64 ed25519 over the lowercase-hex
//     SHA-256 of the document's canonical JSON.
//
// The canonical JSON is the WHOLE document as parsed from YAML, minus the
// top-level `signature` key: object keys sorted at every level, no
// insignificant whitespace, no HTML escaping. Unlike modindex (which names the
// signed fields), nothing is left out, so a field added later is covered
// without a scheme change and a verifier needs no knowledge of the schema: it
// parses the YAML generically, drops `signature`, and serialises. To keep that
// serialisation identical in every language, values are restricted to
// strings, integers, booleans, lists and maps (no floats, nulls, timestamps),
// and strings may not hold control characters or U+2028/U+2029 — the
// characters JSON encoders disagree on.
//
// The private key is the PKCS8 DER, base64 — the format doze-registry's
// keygen writes — read from DZB_SIGNING_KEY. It is never printed.

// signingKeyEnv names the environment variable that holds the signing key.
const signingKeyEnv = "DZB_SIGNING_KEY"

// signingKey reads DZB_SIGNING_KEY.
func signingKey() (ed25519.PrivateKey, error) {
	raw := strings.TrimSpace(os.Getenv(signingKeyEnv))
	if raw == "" {
		return nil, fmt.Errorf("%s is not set (the PKCS8 base64 ed25519 key that signs the indexes)", signingKeyEnv)
	}
	return parseSigningKey(raw)
}

func parseSigningKey(b64 string) (ed25519.PrivateKey, error) {
	der, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("%s is not base64", signingKeyEnv)
	}
	k, err := x509.ParsePKCS8PrivateKey(der)
	if err != nil {
		return nil, fmt.Errorf("%s is not a PKCS8 key", signingKeyEnv)
	}
	priv, ok := k.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%s is not an ed25519 key", signingKeyEnv)
	}
	return priv, nil
}

// publicKeyB64 is the raw 32-byte public key, base64: the form keys.json and
// doze embed.
func publicKeyB64(priv ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
}

// signHex signs a lowercase-hex digest string.
func signHex(priv ed25519.PrivateKey, hexSum string) string {
	return base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(strings.ToLower(hexSum))))
}

func verifyHex(pub ed25519.PublicKey, hexSum, sigB64 string) bool {
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(pub, []byte(strings.ToLower(hexSum)), sig)
}

// canonicalJSON renders a parsed YAML document, minus its top-level
// signature, as canonical JSON.
func canonicalJSON(doc map[string]any) ([]byte, error) {
	payload := make(map[string]any, len(doc))
	for k, v := range doc {
		if k == "signature" {
			continue
		}
		payload[k] = v
	}
	if err := checkCanonical(payload, ""); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	// encoding/json sorts map keys; Encode appends a newline the form has not.
	if err := enc.Encode(payload); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// checkCanonical refuses any value whose JSON form encoders disagree on.
func checkCanonical(v any, path string) error {
	switch t := v.(type) {
	case map[string]any:
		for k, e := range t {
			if err := checkString(k, path); err != nil {
				return err
			}
			if err := checkCanonical(e, path+"."+k); err != nil {
				return err
			}
		}
	case []any:
		for i, e := range t {
			if err := checkCanonical(e, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
	case string:
		return checkString(t, path)
	case int, int64, uint64, bool:
	default:
		return fmt.Errorf("index%s: a %T can't be signed portably (quote it as a string)", path, v)
	}
	return nil
}

func checkString(s, path string) error {
	for _, r := range s {
		if r < 0x20 || r == 0x7f || r == ' ' || r == ' ' {
			return fmt.Errorf("index%s: %q holds a control character, which can't be signed portably", path, s)
		}
	}
	return nil
}

// documentDigest is the lowercase-hex SHA-256 of a YAML document's canonical
// JSON (its signature excluded).
func documentDigest(data []byte) (string, error) {
	var doc map[string]any
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return "", fmt.Errorf("parsing index: %w", err)
	}
	if doc == nil {
		return "", fmt.Errorf("index is empty")
	}
	payload, err := canonicalJSON(doc)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:]), nil
}

// signDocument appends the document signature to YAML that carries none: the
// signature is computed over the bytes as they will be read back.
func signDocument(data []byte, priv ed25519.PrivateKey) ([]byte, error) {
	var doc map[string]any
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("parsing index: %w", err)
	}
	if _, ok := doc["signature"]; ok {
		return nil, fmt.Errorf("index is already signed")
	}
	digest, err := documentDigest(data)
	if err != nil {
		return nil, err
	}
	out := append([]byte(nil), data...)
	if len(out) > 0 && out[len(out)-1] != '\n' {
		out = append(out, '\n')
	}
	out = append(out, "signature: \""+signHex(priv, digest)+"\"\n"...)
	return out, nil
}

// verifyDocument checks a signed YAML document: the document signature, and
// every `sig` beside a `sha256` anywhere in it (artifacts). It returns how many
// artifact signatures it checked; an artifact without a sig is an error.
func verifyDocument(data []byte, pub ed25519.PublicKey) (int, error) {
	var doc map[string]any
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return 0, fmt.Errorf("parsing index: %w", err)
	}
	sig, _ := doc["signature"].(string)
	if sig == "" {
		return 0, fmt.Errorf("index is unsigned (no signature)")
	}
	digest, err := documentDigest(data)
	if err != nil {
		return 0, err
	}
	if !verifyHex(pub, digest, sig) {
		return 0, fmt.Errorf("index signature does not match the key")
	}
	n := 0
	var walk func(v any, path string) error
	walk = func(v any, path string) error {
		switch t := v.(type) {
		case map[string]any:
			if sum, ok := t["sha256"].(string); ok {
				s, _ := t["sig"].(string)
				if s == "" {
					return fmt.Errorf("%s: artifact has no sig", path)
				}
				if !verifyHex(pub, sum, s) {
					return fmt.Errorf("%s: artifact sig does not match the key", path)
				}
				n++
				return nil
			}
			keys := make([]string, 0, len(t))
			for k := range t {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				if err := walk(t[k], path+"."+k); err != nil {
					return err
				}
			}
		case []any:
			for i, e := range t {
				if err := walk(e, fmt.Sprintf("%s[%d]", path, i)); err != nil {
					return err
				}
			}
		}
		return nil
	}
	if err := walk(doc, ""); err != nil {
		return 0, err
	}
	return n, nil
}

// runSign is `dzb sign <index.yaml>`: sign an engine mirror index in place —
// a sig on every artifact, then the document signature. Signatures already in
// the file (a re-download of the published index) are dropped and recomputed;
// ed25519 is deterministic, so an unchanged entry gets the same bytes.
func runSign(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: dzb sign <index.yaml>   (key in %s)", signingKeyEnv)
	}
	priv, err := signingKey()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	var man manifest
	if err := yaml.Unmarshal(data, &man); err != nil {
		return fmt.Errorf("parsing %s: %w", args[0], err)
	}
	out, err := signManifest(man, priv)
	if err != nil {
		return err
	}
	return os.WriteFile(args[0], out, 0o644)
}

// signManifest renders an engine mirror index with every artifact signed and
// the document signature appended.
func signManifest(man manifest, priv ed25519.PrivateKey) ([]byte, error) {
	for _, em := range man.Engines {
		if em == nil {
			continue
		}
		for _, triples := range em.Artifacts {
			for t, a := range triples {
				a.SHA256 = strings.ToLower(a.SHA256)
				a.Sig = signHex(priv, a.SHA256)
				triples[t] = a
			}
		}
	}
	man.Signature = ""
	body, err := yaml.Marshal(man)
	if err != nil {
		return nil, err
	}
	return signDocument(body, priv)
}

// runVerifySig is `dzb verify-sig <index.yaml> <public key, base64>`: check
// a signed index the way doze will. With "-" as the key, the public half of
// DZB_SIGNING_KEY is used (CI checks what it just signed).
func runVerifySig(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: dzb verify-sig <index.yaml> <public key base64 | ->")
	}
	var pub ed25519.PublicKey
	if args[1] == "-" {
		priv, err := signingKey()
		if err != nil {
			return err
		}
		pub = priv.Public().(ed25519.PublicKey)
	} else {
		raw, err := base64.StdEncoding.DecodeString(args[1])
		if err != nil || len(raw) != ed25519.PublicKeySize {
			return fmt.Errorf("public key must be %d bytes, base64", ed25519.PublicKeySize)
		}
		pub = raw
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	n, err := verifyDocument(data, pub)
	if err != nil {
		return fmt.Errorf("%s: %w", args[0], err)
	}
	fmt.Printf("%s: signature ok, %d artifact signatures ok\n", args[0], n)
	return nil
}

// runPubkey is `dzb pubkey`: the public half of DZB_SIGNING_KEY, base64 — what
// doze embeds to verify these indexes. The private key is never printed.
func runPubkey(args []string) error {
	if len(args) != 0 {
		return fmt.Errorf("usage: dzb pubkey")
	}
	priv, err := signingKey()
	if err != nil {
		return err
	}
	fmt.Println(publicKeyB64(priv))
	return nil
}
