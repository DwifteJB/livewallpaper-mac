
# Live Wallpaper for MacOS

![app image](https://raw.githubusercontent.com/DwifteJB/livewallpaper-mac/refs/heads/main/.github/readme/app-screenshot.png)

TODO: get a better name

Super simple livewallpaper picker build w/ swift, instead of paying for a subscription / one time just use this! find any mp4 online and use it here :)

## how does it work??

it works by putting a window behind the icons but above the actual wallpaper itself. once its ran it uses the first frame for the macos accent and sets it as the actual wallpaper, then transcodes into a MOV file (so the GPU can be utilised properly) then loops and plays the video. its quite simple.

## How to build


### Binary
Ensure that you have xcode or xcode command line tools. The build downloads a static ffmpeg into `vendor/` on first run (needs an internet connection once).

```
zsh ./build.sh
./build/livewallpaper
```

### App

```
zsh ./build-app.sh
open ./build/LiveWallpaper.app
```

## How to use

You can open the program, or run the binary and then in the top right you can click to open, select a mp4 / any video format that mac usually supports & then it'll play. Or you can run it via the CLI

```
./livewallpaper "path/to/file.mp4"
```
