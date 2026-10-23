# Orange product site

A static, dependency-free GitHub Pages site. Publish this directory as the Pages artifact. The deployment URL is `https://shamsu07.github.io/orange/`.

- `index.html`: product page and download links.
- `guide/index.html`: separate usage guide.
- `styles.css`: shared responsive design and reduced-motion behavior.
- `app.js`: keyboard-accessible illustrative wheel. It never accepts or uploads files.
- `assets/`: Orange's original app icon and native screenshots.
- `check.py`: dependency-free local link, fragment and basic markup checks.

The site uses system fonts, no analytics and no third-party scripts, fonts or embeds. Downloads use the stable GitHub Releases asset alias `Orange-macos-arm64.dmg`. Every stable release must upload that alias alongside its versioned disk image. Download links must match an actual release asset. App screenshots must come from Orange; clearly label illustrations.

For a local preview, start a static server at the repository root and open `/site/`. No build step is needed.

Native screenshots are `wheel-preview.png`, `image-resize.png` and `video-snapshot.png`. Capture them from the release build, without personal paths or private file contents. The wheel in the hero is explicitly labeled as an illustration.

Before publishing, run `python3 site/check.py` and `node --check site/app.js` from the repository root. Also review the rendered landing page and guide at desktop and phone widths; markup checks do not prove visual accessibility.
