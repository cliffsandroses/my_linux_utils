# wardrobe

- **I want to:** see everything in my wardrobe in one place, and talk to it ("what do I wear to…", "what haven't I worn").
- **Where I'll use it:** phone (adding clothes, deciding), Soma (Vault → Wardrobe).
- **Done when:** every piece is in it with a photo, I can filter and build outfits, and Claude/the local model can suggest
  outfits from what's actually there.
- **Must never:** upload photos anywhere outside the homelab.

## Existing FOSS checked
- OpenWardrobe-style apps on F-Droid are thin (no sync, no AI). Immich holds the photos already. Building it as a Soma page
  is the light path.

## Plan
1. **Add a piece:** phone photo (Soma's camera button) → rembg cuts it out on the homelab → a free vision model tags it
   (type, colour, pattern, season, formality); you fix tags with chips.
2. **The wardrobe:** a grid of cut-outs by type (tops, bottoms, shoes, layers, accessories), filters, wear count, last worn.
3. **Outfits:** drag pieces onto a mannequin board; save outfits; "worn today" adds a wear.
4. **Ask it:** "something for a wedding", "dress for 32 °C", "what's never worn": FreeLLMAPI or Claude reads the tagged
   list (not the photos) and answers with picks from your own clothes, shown as cards.
5. **Clear-outs:** pieces unworn for 6 months go to forge `sell-it` or donate.

Stack: a Soma page + `/api/wardrobe` (JSON in the vault: `wardrobe/items.json`, photos in Immich album "Wardrobe").
