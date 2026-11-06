# OtherContexts

A fork of [OpenContexts](https://opencontexts.app/): a free, open-source window switcher for macOS.

To avoid confusion with the original, this fork is named OtherContexts, but the is only skin deep:
internal names still call it "OpenContexts".

I appreciate the work [Zheng Sihua](https://github.com/zshnb) and others put into the original
version of this app. However, my preferences differ from their design and roadmap, hence I forked
it and changed it to better fit how I like to work.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project OpenContexts.xcodeproj -scheme OpenContexts -configuration Release build
```

### Testing

Run the tests with `swift test`.

Some tests verify windows activation, and could fail if another app takes focus while they run (for
example, because the user is doing some work while the tests run in the background). To avoid that,
leave the machine idle while the tests run, or at least rerun those tests on their own with `swift
test --filter testActivation`.


## Acknowledging AI Use

This code was written with assistance from the following AI models:

- Claude Opus 5.5 (Anthropic)
- GPT-6-Luna (OpenAI)

## License

This software is licensed under the terms of the [Apache License, Version 2.0](LICENSE).
