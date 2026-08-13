#!/usr/bin/env nu

# Fetch public-domain speech recordings and convert them to the 16 kHz mono WAV
# that libwhisper's benchmark and optional model test expect.
#
#   nu scripts/fetch-speeches.nu
#   nu scripts/fetch-speeches.nu --max-seconds 60 --out-dir /tmp/speeches
#   nu scripts/fetch-speeches.nu --author douglass --limit 2
#
# Then, for example:
#   zig build bench-libwhisper -Doptimize=ReleaseFast -- \
#     ~/.bobrwhisper/models/ggml-tiny.bin corpus/speeches/<file>.wav
#
# LibriVox is the only source here, and deliberately so: every LibriVox
# recording is public domain worldwide, so there is nothing to attribute and
# nothing to re-license. Filtering a general archive by an open licence does not
# give the same guarantee — the licence describes the rights, not the contents,
# and an unattended search will happily return material nobody wants vendored
# into a repository. Anything added here should come with the same guarantee.

const api = "https://librivox.org/api/feed/audiobooks"

# Reproducible defaults, so repeated runs benchmark the same audio. Each is a
# recording of a public-domain speech rather than an audiobook chapter.
const default_projects = [
    389 # Lincoln, Gettysburg Address (short)
    264 # Lincoln, address at Cooper Union
    10457 # Cicero, Speeches Against Catilina
]

def main [
    --out-dir: string = "corpus/speeches" # destination for the WAV files and manifest
    --max-seconds: int = 120 # trim each recording; 0 keeps the full length
    --limit: int = 3 # maximum recordings to fetch
    --author: string # search LibriVox by author instead of using the defaults
    --title: string # search LibriVox by title instead of using the defaults
    --keep-source # keep the downloaded source audio next to the WAV
] {
    if (which ffmpeg | is-empty) {
        error make {msg: "ffmpeg is required to resample to 16 kHz mono WAV"}
    }

    let books = if ($author | is-not-empty) or ($title | is-not-empty) {
        search-books $author $title $limit
    } else {
        $default_projects | first ([$limit ($default_projects | length)] | math min) | each { |id| fetch-book $id }
    }

    if ($books | is-empty) {
        error make {msg: "no LibriVox recordings matched"}
    }

    mkdir $out_dir
    let entries = $books | each { |book| fetch-one $book $out_dir $max_seconds $keep_source } | compact

    let manifest = $out_dir | path join "manifest.json"
    {
        source: "LibriVox (https://librivox.org)"
        license: "Public domain"
        sample_rate: 16000
        channels: 1
        encoding: "pcm_s16le"
        recordings: $entries
    } | to json --indent 2 | save --force $manifest

    print $"\nWrote ($entries | length) recording\(s\) and ($manifest)"
    $entries | select title seconds path
}

# LibriVox returns its own JSON content type, so decode explicitly rather than
# relying on content negotiation.
def get-json [url: string] {
    http get --raw --max-time 2min $url | from json
}

def books-of [response: record] {
    if "books" in ($response | columns) { $response.books } else { [] }
}

def search-books [author: any, title: any, limit: int] {
    mut url = $"($api)/?format=json&extended=1&limit=($limit)"
    if ($author | is-not-empty) { $url = $"($url)&author=($author)" }
    # A leading ^ makes LibriVox match a title prefix rather than the whole string.
    if ($title | is-not-empty) { $url = $"($url)&title=^($title)" }
    books-of (get-json $url)
}

def fetch-book [id: int] {
    let found = books-of (get-json $"($api)/?format=json&extended=1&id=($id)")
    if ($found | is-empty) {
        print $"warning: LibriVox project ($id) returned nothing, skipping"
        null
    } else {
        $found | first
    }
}

def fetch-one [book: any, out_dir: string, max_seconds: int, keep_source: bool] {
    if ($book | is-empty) { return null }

    let sections = if "sections" in ($book | columns) { $book.sections } else { [] }
    if ($sections | is-empty) {
        print $"warning: ($book.title) has no audio sections, skipping"
        return null
    }

    # One section keeps downloads small; --max-seconds trims further.
    let section = $sections | first
    let listen_url = canonical-url $section.listen_url
    let slug = slugify $book.title
    let source_ext = ($listen_url | path parse | get extension)
    let source_path = $out_dir | path join $"($slug).($source_ext)"
    let wav_path = $out_dir | path join $"($slug).wav"

    print $"fetching ($book.title) ..."
    # Recordings run to tens of megabytes, well past the default request timeout.
    # A single unavailable item should not abandon the rest of the batch.
    let downloaded = try {
        http get --raw --max-time 10min $listen_url | save --raw --force $source_path
        true
    } catch { |err|
        print $"warning: could not download ($book.title): ($err.msg)"
        false
    }
    if not $downloaded { return null }

    let trim = if $max_seconds > 0 { [-t ($max_seconds | into string)] } else { [] }
    let result = do {
        ^ffmpeg -nostdin -loglevel error -y -i $source_path ...$trim -ac 1 -ar 16000 -acodec pcm_s16le $wav_path
    } | complete
    if $result.exit_code != 0 {
        print $"warning: ffmpeg failed for ($book.title): ($result.stderr)"
        return null
    }

    if not $keep_source { rm --force $source_path }

    let section_seconds = try { $section.playtime | into int } catch { 0 }
    let seconds = if $max_seconds > 0 and $section_seconds > 0 {
        [$max_seconds $section_seconds] | math min
    } else if $section_seconds > 0 {
        $section_seconds
    } else {
        # Fall back to the WAV itself: 44-byte header, 2 bytes per mono sample.
        (((ls $wav_path | first | get size | into int) - 44) / 2 / 16000) | math round
    }

    {
        title: $book.title
        librivox_id: $book.id
        section: $section.section_number
        seconds: $seconds
        path: $wav_path
        listen_url: $listen_url
        librivox_url: (if "url_librivox" in ($book | columns) { $book.url_librivox } else { null })
        text_source: (if "url_text_source" in ($book | columns) { $book.url_text_source } else { null })
        language: (if "language" in ($book | columns) { $book.language } else { null })
        license: "Public domain"
    }
}

# LibriVox stores www.archive.org URLs, but that host stalls indefinitely for
# some items where the canonical archive.org serves them fine.
def canonical-url [url: string] {
    $url | str replace "https://www.archive.org/" "https://archive.org/"
}

def slugify [text: string] {
    $text
    | str lowercase
    | str replace --all --regex '[^a-z0-9]+' '-'
    | str trim --char '-'
}
