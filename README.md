# open-contexts

A fork of [OpenContexts](https://opencontexts.app/): a free, open-source window switcher for macOS.

I appreciate the efforts by [Zheng Sihua](https://github.com/zshnb) and others in building the
original version of this app. But my preferences for it differs than their design and roadmap, and
as such I decided to fork this, and change it to better fit how I would like it to work.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project OpenContexts.xcodeproj -scheme OpenContexts -configuration Release build
```

The ad-hoc signed app is written to `build/Build/Products/Release/OpenContexts.app`. Omit the
`ARCHS` and `ONLY_ACTIVE_ARCH` settings to build for the native architecture only, and pass
`CURRENT_PROJECT_VERSION=<n>` to set the build number.

Run the tests with `swift test`.

## Acknowledging AI Use

This code was written with assistance from the following AI models:

- Claude Opus 5.5 (Anthropic)
- GPT-6-Luna (OpenAI)

## License

This software is licensed under the terms of the [Apache License, Version 2.0](LICENSE).
