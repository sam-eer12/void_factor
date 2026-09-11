# Firestore rules tests

Asserts `firestore.rules` from the outside, as a client sees it. Reading the
rules and agreeing with them is not the same as knowing they deny anything —
these fail loudly if the file is ever loosened.

## Running

The Firestore emulator needs **JDK 21 or newer** (firebase-tools dropped
anything older). There is no `java` on this machine's PATH, but Android Studio
ships a JetBrains Runtime that qualifies:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"
npm install
npm test
```

With no Android Studio and no JDK, run it in a container instead:

```sh
podman run --rm -v "$PWD/..:/work:Z" -w /work/test_rules node:22-trixie sh -c '
  apt-get update -qq && apt-get install -y -qq openjdk-21-jre-headless
  npm install --silent && npm install --silent --no-save firebase-tools
  npx --no-install firebase emulators:exec --only firestore \
      --project demo-void-factor "node --test rules.test.mjs"'
```

Note `node:22-trixie`, not `bookworm`: Debian 12 carries only JDK 17, which
firebase-tools now refuses.

## Deploying the rules

```sh
firebase deploy --only firestore:rules --project signinpractice-bfade
```

Tests passing locally means the file is correct. It does **not** mean it is
live — until that deploy runs, the project is still enforcing whatever it had
before, which was nothing.
