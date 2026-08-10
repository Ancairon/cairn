# record_reccomend

An open-source, album-first music discovery app. See an album, play it via a deep link into whatever streaming app you have installed, rate it 1-5 stars, and get a new recommendation based on that rating — built around full-album discovery rather than the repeat-track optimization most streaming algorithms favor.

## Status

Early days: the terminal app + local data layer (Milestone 1) is under construction. The mobile UI comes later, on top of the same code.

No API keys, no login, no backend — every data source it talks to (MusicBrainz, Cover Art Archive, ListenBrainz Labs, Odesli) is public and keyless.

## Running the terminal app

```sh
dart pub get
dart run bin/cli.dart
```

## Running tests

```sh
dart test
```
