# record_reccomend

An open-source, album-first music discovery app. See an album, play it via a deep link into whatever streaming app you have installed, rate it 1-5 stars, and get a new recommendation based on that rating — built around full-album discovery rather than the repeat-track optimization most streaming algorithms favor.

## Status

Milestone 1 (terminal app + local data layer) works end-to-end against the real live APIs. The mobile UI comes later, on top of the same code.

No API keys, no login, no backend — every data source it talks to (MusicBrainz, Cover Art Archive, ListenBrainz Labs, Odesli) is public and keyless.

## Running the terminal app

```sh
dart pub get
dart run bin/cli.dart next                    # get a recommended album
dart run bin/cli.dart rate <album-mbid> 1-5    # rate it; prints the next recommendation
dart run bin/cli.dart journal                  # list everything you've rated
dart run bin/cli.dart export-json               # export your journal as JSON
dart run bin/cli.dart export-csv                # export your journal as CSV
```

Local data lives in `record_reccomend.db` (SQLite) in the working directory — not committed to git.

## Running tests

```sh
dart test
```
