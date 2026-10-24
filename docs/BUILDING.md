# Building Inframy

```
brew install xcodegen
xcodegen generate
xcodebuild -scheme Inframy -configuration Release build
swift test --package-path Packages/InframyKit
```

## Code signing (why permissions stick)

macOS remembers Photos and local-network permissions per app *signature*. Ad hoc builds get a new signature
every time, so macOS would ask again after each rebuild. Inframy is signed with a local, self-made certificate
named **Inframy Local Signing** in the login keychain (no Apple developer account needed), so every build has the
same identity. Its designated requirement is the bundle id plus that certificate.

To recreate it on another Mac:

```
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Inframy Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "Inframy Local Signing" -out inframy.p12 -passout pass:x
security import inframy.p12 -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
rm key.pem inframy.p12
```

"Not trusted" in `security find-identity` is expected and fine for local use. A new certificate means a new
identity, so macOS asks for permissions once more.
