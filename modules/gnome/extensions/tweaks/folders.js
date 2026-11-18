// SPDX-License-Identifier: GPL-2.0-or-later
// tweaks/folders.js: the colour of Ubuntu's folder icons (the Yaru icon theme's variants), pure so
// the gjs tests run it. The owner, 2026-11-01: folders follow the accent by default, or take any
// Yaru colour picked in Ostrich Settings > Theme (folder-colour).

/** Yaru's folder colours, as the folder-colour setting names them ('default' is Yaru's orange). */
export const COLOURS = ['default', 'bark', 'sage', 'olive', 'viridian', 'prussiangreen', 'blue', 'purple', 'magenta', 'red'];

// GNOME's accent colours (org.gnome.desktop.interface accent-color) -> the nearest Yaru colour.
const FOR_ACCENT = {
    blue: 'blue', teal: 'prussiangreen', green: 'viridian', yellow: 'olive', orange: 'default',
    red: 'red', pink: 'magenta', purple: 'purple', slate: 'sage',
};

/**
 * The icon theme to use, or null to leave it as it is.
 *
 * @param {object} s
 * @param {string} s.current  the icon theme now: only a Yaru theme is changed (yours stays)
 * @param {string} s.choice   folder-colour: 'accent' or one of COLOURS
 * @param {string} s.accent   accent-color
 * @param {boolean} s.dark    the dark style (Yaru's -dark variants)
 * @param {string|null} s.scheme  the colour scheme applied (`ostrich theme scheme`); with one, it
 *     sets the folders, so following the accent leaves them as the scheme set them
 * @returns {string|null}
 */
export function folderTheme({current, choice, accent, dark, scheme}) {
    if (!/^Yaru(-[a-z]+)?(-dark)?$/.test(current))
        return null;
    let colour;
    if (choice !== 'accent')
        colour = COLOURS.includes(choice) ? choice : null;
    else if (!scheme || scheme === 'classic')
        colour = FOR_ACCENT[accent] ?? null;
    if (!colour)
        return null;
    const theme = `${colour === 'default' ? 'Yaru' : `Yaru-${colour}`}${dark ? '-dark' : ''}`;
    return theme === current ? null : theme;
}
