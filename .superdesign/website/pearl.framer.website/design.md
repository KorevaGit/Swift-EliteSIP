---
version: "superdesign-alpha"
name: "Bicolor Editorial Portfolio"
description: "White-dominant editorial system with two-tone display headlines (black lead-in, gray trailing clause), black pill CTAs, and gray-panel media cards on a strict two-column rhythm."
colors:
  background: "#FFFFFF"
  surface: "#D8D8F0"
  surface-dark: "#000000"
  text-primary: "#000000"
  text-secondary: "#969696"
  text-muted: "#666666"
  accent-link: "#0000EE"
typography:
  display-lg:
    fontFamily: "Manrope"
    fontSize: "64px"
    fontWeight: 500
    lineHeight: "1.2"
  body-md:
    fontFamily: "Manrope"
    fontSize: "16px"
    fontWeight: 500
    lineHeight: "1.4"
  label-md:
    fontFamily: "Manrope"
    fontSize: "18px"
    fontWeight: 500
    lineHeight: "1.4"
  body-charweighted:
    fontFamily: "Manrope"
    fontSize: "24px"
    fontWeight: 500
    lineHeight: "1.4"
  accent-serif:
    fontFamily: "Times New Roman"
    fontStyle: "normal"
spacing:
  base: "8px"
  gap: "40px"
  gap-sm: "16px"
  gap-md: "24px"
  section-padding: "10px"
rounded:
  control: "11px"
  card: "24px"
  pill: "200px"
  hero-radius: "64px"
components:
  button-primary:
    background: "#000000"
    text-color: "#FFFFFF"
    radius: "9999px"
    height: "56px"
    note: "observed near-black solid pill, ~28px corner radius, hero CTA under headline"
  button-nav-cta:
    background: "transparent"
    text-color: "#0000EE"
    radius: "64px"
    height: "41px"
  button-secondary-pill:
    background: "#F0F0F0"
    text-color: "#000000"
    radius: "9999px"
    height: "44px"
    note: "used mid-page beside section headlines"
  card-media-gray:
    background: "#D8D8F0"
    radius: "24px"
    padding: "0px"
    border: "none"
  card-media-dark:
    background: "#000000"
    radius: "24px"
    padding: "0px"
    border: "none"
  navbar:
    background: "transparent"
    height: "41px"
    width: "92%"
    radius: "0px"
    shadow: "none"
---
# Bicolor Editorial Portfolio
Source: https://pearl.framer.website/

## Overview
This is a minimalist, editorial-typographic system built almost entirely in a white-dominant field (pixel field ~65% pure white, ~15% pale lavender-gray panels), with black used as a rationed structural color rather than a background — it appears only as a full-bleed footer band and as small accent panels. The identity is carried by large Manrope display type set in a signature bicolor clause (black lead-in words, gray trailing words) repeated at every major section transition, paired with pill-shaped black CTAs and soft lavender-gray (#D8D8F0) rectangular media panels holding wireframe app screenshots. It reads as a design-agency portfolio aesthetic: content-first, grid-strict, Swiss-adjacent in its restraint but softened by rounded card geometry and a pastel surface tint instead of hard rules.

## Composition
The first screen opens with a small two-part eyebrow label, then the oversized bicolor headline, then a single black pill CTA, then nothing else until a large gray media panel begins the scroll — a deliberately sparse hero that rejects a hero image or gradient wash in favor of pure typographic weight. Below the fold the rhythm alternates: a full-width gray showcase panel, then a two-column row of gray/dark media cards with caption pairs beneath each (small gray label + black title), repeating this card-pair unit multiple times down the page. A services list (stacked single-column rows with a divider rule and a trailing arrow glyph) breaks the card rhythm before the next bicolor headline band appears with a pill CTA at its right edge. The page closes on a large full-bleed black footer panel — the one deliberate saturated moment in an otherwise white composition, rejecting a colorful decorative footer in favor of a stark tonal reversal.

## Colors
Background white (#FFFFFF) dominates at roughly two-thirds of rendered pixels and is the true page canvas; the pale lavender-gray #D8D8F0 (~15%) is the surface role for every media/showcase card, giving all imagery a consistent tinted frame rather than a white or dark card background. Pure black (#000000, ~8% combined with #181818 near-blacks) is reserved for the footer band and for card fills that hold dark app-screenshot content, plus all primary CTA fills and body text ink. #969696 and #666666 serve as the secondary/muted text tones used for the trailing clause of every headline and for eyebrow/caption labels — this gray-on-black-text pairing is the system's core hierarchy device. #0000EE appears only as the navbar's CTA text/link color, an untouched default link-blue kept legible and small. No warm hue, no gradient, and no saturated brand color exists anywhere; color is entirely tonal (black/white/gray/lavender-gray) with blue rationed to a single nav element.

## Typography
Manrope is the sole UI typeface across all weights (500 throughout — no bold jump), carrying eyebrow labels at ~18px, body copy at 16–24px depending on context, and display headlines at 64px/1.2 line-height. The signature move is splitting every major headline into a black-ink first clause and a #969696 gray second clause within the same sentence and size — never a size or weight change, purely a color break — applied to 100% of section headlines observed (hero, mid-page CTA band, footer-adjacent story band). A residual Times New Roman serif token exists in the family stack but is not visually deployed as an accent in the observed screens; treat it as a dormant fallback rather than a display device. Line-height stays generous (1.2–1.4) across all sizes, reinforcing the airy, unhurried editorial pacing.

## Layout
Content sits in a very wide container (max-width 1800px) with generous 80px-class outer margins mirrored in the navbar inset. The core repeating structure is a 2-column card grid, gap 40px, with rows behaving as roughly equal-width pairs (measured 49/49 splits) — i.e., two same-size cards per row, never asymmetric spans; a single full-width 1-column row (gap 40px) is used for the top showcase panel. A separate 5-column, 0-gap, 10-item grid appears nested inside the navbar's contained set (a dense micro-grid, rows of 5/5, tile-like, used for interface chrome rather than page content). Card radius is a soft 24px throughout, with the hero visual band and largest showcase panel taking a much larger 64px radius. Vertical rhythm is generous and uneven by design — big empty white gaps separate the compact stacked services list from the surrounding headline bands, giving the page a slow, breathing density rather than a packed dashboard feel.

## Components
- **Navbar**: wide inset square-cornered bar (not full-bleed, not a capsule) — 1760px wide at this viewport, 92% of viewport with matching 80px left/right insets, 41px tall, all four corner radii 0px (a flat rectangular strip, sharp not rounded), background fully transparent so it floats over the white page, 5 nav items, static (no scroll transform observed). Its CTA sits at the right: black text `#000000`/link-blue `#0000EE`, pill radius 64px, height 41px, transparent fill — a text-forward nav utility, not a solid button.
- **Hero primary CTA**: one solid black pill beneath the headline, observed near-black (#000000) fill with white/cream text, full pill radius (~28px on a ~56px height), sitting alone with no secondary button beside it — the single highest-contrast interactive element on the first screen.
- **Secondary pill CTA**: a light gray (#F0F0F0) pill button, e.g. beside the mid-page and pre-footer bicolor headlines, black text, fully rounded — a lower-emphasis companion to the black hero CTA, used to link to deeper content sections.
- **Media showcase card (full-width)**: one per major project intro, gray #D8D8F0 fill, 24–64px radius, no border, holds a dark-UI dashboard screenshot centered and inset with generous padding, a small circular arrow-glyph badge in the bottom-left corner; caption pair (gray eyebrow label + black title line) sits directly below the panel, outside the card bounds.
- **Media card pair (2-up row)**: two cards per row across the grid, equal width (~49/49 split), alternating dark (#000000) and gray (#D8D8F0) fills; dark cards center a colored abstract mark or icon-like graphic filling roughly half the card height, gray cards center a small light-surface UI screenshot (card/summary widget style) inset with padding; each card carries the same corner-badge arrow glyph, with gray eyebrow + black title caption pair beneath.
- **Services list**: single-column stacked rows, each a large black label with a downward arrow glyph at the far right, separated by hairline dividers (`rgb(217,217,217) 0px 1px 0px 0px`-style rule); rows are uniform height, no icons, no body copy — a pure disclosure-style list implying expandable content.
- **Footer**: full-bleed black band (#000000), 9 links, generous top/bottom padding, small muted-gray fine-print line sitting at the lower-left; otherwise empty black space above the link row, reinforcing the stark tonal break from the white body.
- **Card shadow/border treatment**: crisp cards use a hairline light-gray top shadow (`rgb(217,217,217) 0px 1px 0px 0px`) plus a 1px inset black border (`rgb(0,0,0) 0px 0px 0px 1px inset`) for flat UI-chrome elements (dropdown/app-plugin screenshot insets); floating elements (badge, corner arrow) use a soft multi-layer elevation shadow (`rgba(0,0,0,0.17) 0px 0.6px 1.57px -1.5px, rgba(0,0,0,0.14) 0px 2.29px 5.95px -3px, rgba(0,0,0,0.02) 0px 10px 26px -4.5px`).

## Graphics & Effects
No gradients, mesh backgrounds, or scrims appear anywhere in this system — every surface is a flat fill (white page, lavender-gray card, or black band). Imagery is exclusively rendered as flat-color app/dashboard screenshots and thin-line wireframe illustrations (isometric device/card sketches in a single mid-gray stroke) sitting inside the gray panels; these stand in for any "live" product demo, framed by generous internal padding rather than bleeding to the card edge. Elevation is expressed only through the two shadow recipes cited above — a hairline top-edge shadow with inset border for flat chrome elements, and a soft diffused multi-stop shadow for floating corner badges — never through blur/glass treatments. No texture, grain, or pattern overlay is present; the surface language stays perfectly flat and matte throughout.

## Motion
Observed motion infrastructure is framer-motion driven with lenis smooth-scroll, plus a `__framer-loading-spin` keyframe reserved for a loading-spinner state. No scroll-linked parallax or staggered reveal choreography is evidenced beyond standard scroll-triggered entrance behavior implied by the framer-motion dependency; treat motion as restrained — smooth momentum scrolling and simple fade/slide entrances rather than expressive or springy transforms, consistent with the system's quiet editorial tone.

## Guardrails
- Never fill the hero or any section background with a gradient or dark wash — the canvas stays white; color is confined to gray card panels and the single black footer band.
- Never render section headlines in a single flat color — preserve the two-clause black-then-gray split within one sentence at the same size and weight.
- Never square off the card panels — media cards keep a soft 24px (or larger 64px for the primary showcase) radius, never sharp corners.
- Never turn the navbar into a full-bleed or capsule bar — it is a flat, transparent, sharp-cornered inset strip with matched left/right margins.
- Never substitute a glass/blur treatment for shadows — elevation comes only from the two flat shadow recipes specified, no backdrop-filter anywhere.
- Keep blue (#0000EE) confined to the nav CTA text; do not spread it into body links or buttons elsewhere.