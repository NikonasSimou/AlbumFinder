# Album Finder

An iPhone app that finds the music recommended in a TikTok or Instagram video and links each album in Apple Music.

Save the video to Photos, pick it in the app, and choose who finds the music: Apple's on-device model, or Claude through the Claude API. Each video becomes a folder named after it and the date, with every recommendation labelled (album, song or band) and the albums only mentioned in passing listed separately. With Claude, each recommendation also gets a short description of how the person in the video talks about it.

## How it works

```mermaid
flowchart TD
    A["Pick a saved video from Photos<br/>and choose On device or Claude"] --> B["Start background run<br/>(keeps going if you leave the app)"]
    B --> S1 & V1

    subgraph Listen["1 · Listen (on device)"]
        S1["Pull out the audio"] --> S2["Speech to text<br/>SpeechTranscriber"]
        S2 --> S3["Transcript<br/>(if it fails, carry on with screen text only)"]
    end

    subgraph Read["2 · Read the screen (on device)"]
        V1["Take a frame every 1.5 s"] --> V2["Text recognition<br/>overlays, captions, cover text"]
        V1 --> V3{"Frame looks new?"}
        V3 -- yes --> V4["Fingerprint the frame and anything<br/>cover-shaped in it"]
    end

    S3 --> P1
    V2 --> P1

    subgraph Understand["3 · Find the music"]
        P1["Clean the screen text<br/>drop @handles and spoken subtitles,<br/>join 'Title' + 'by Artist' lines"] --> E{"On device or Claude?"}
        E -- On device --> P2["Fit transcript + screen text<br/>into the model's ~4,000 tokens"]
        P2 --> P3["Apple's model lists up to 30 entries:<br/>artist, title, and kind<br/>album · song · band · mention"]
        E -- Claude --> Q1["Send transcript + screen text<br/>to the Claude API (Haiku 5.5 by default)"]
        Q1 --> Q2["Claude lists the same entries,<br/>plus how each recommendation is described<br/>(an empty answer is asked again once)"]
        Q1 -. fails .-> Q3{"Ask: try again<br/>or use the on-device model?"}
        Q3 -. try again .-> Q1
        Q3 -. on device .-> P2
        P3 --> P4["Tidy titles and remove repeats"]
        Q2 --> P4
    end

    subgraph Lookup["4 · Apple Music lookup"]
        P4 --> L0{"Band with no album?"}
        L0 -- yes --> L1["Artist page"]
        L0 -- no --> L2["Artist's full catalog → song search →<br/>looser title match → title-only search<br/>(a full album beats a same-named single)"]
        L2 --> L3["Safety net: on-screen 'Title by Artist' lines<br/>• retry a miss with the screen spelling<br/>• add any the model skipped, if found"]
    end

    L1 --> C1
    L3 --> C1
    V4 -.-> C1

    subgraph Covers["5 · Check covers"]
        C1["Compare Apple Music artwork<br/>with the video's fingerprints"] --> C2["Mark 'Cover seen in video', or pick<br/>the artist's album whose cover was shown<br/>(or their only album, for a record not named)"]
    end

    C2 --> F1

    subgraph Finish["6 · Finish"]
        F1["Drop unmatched names that appear<br/>nowhere in the video"] --> F2["Merge duplicates, keeping the stronger label"]
        F2 --> F3["Save folder: video title + date,<br/>albums, transcript, screen text, step timings"]
        F3 --> F4["Notification: 'Albums found'"]
    end
```

## Privacy

The video and its audio never leave the iPhone. The Apple Music lookups send album and artist names to Apple's public iTunes Search API. With Claude chosen, the video's transcript and screen text are also sent to Anthropic.

## Requirements

- An iPhone with Apple Intelligence on iOS 26 or later, for the on-device model.
- For Claude: an API key from [console.anthropic.com](https://console.anthropic.com), entered in the app's Settings. API use is billed by Anthropic, separately from a Claude subscription.
- Xcode to build and install the app. With a free Apple developer account the app has to be reinstalled every 7 days.
