# Nutrition documents (Apple fork)

Food → Nutrition PDFs stores a user-selected nutrition document for Coach to look foods up in. The user
supplies the restaurant/brand and market/country because similarly named products can have different
serving sizes and formulations across markets. There is no built-in restaurant database, automatic web
lookup, publisher authentication, subscription, hosted service or new account.

## Lazy lookup

Nothing is extracted into the food library at import, and there is no review of a whole menu. The app keeps
the document's page text (v56 `nutritionDocument` / `nutritionDocumentPage`) and, optionally, a name index
(`nutritionDocumentIndex`). When the user asks Coach to log something:

1. The app matches what the user said (their last three messages, not Coach's replies) against the index
   and, for pages without one, against the raw lines (`NutritionDocumentLookup.match`).
2. The matched rows go into Coach's context verbatim, each with its key, its source and the nearest header
   line above it on the page, so Coach can read which column is which.
3. Coach proposes `log_document` with the row key and the figures as printed. The app re-reads the row from
   the store and refuses the proposal unless kcal, protein, carbohydrate and fat (and fibre, when given) are
   all printed on that line (`NutritionDocumentLookup.figuresArePrinted`).
4. The confirmation card shows the citation, the header and the row. That card is the review, for the one
   item actually eaten. Confirming logs it and saves it to the food library with its document provenance, so
   the next request is a plain pick from saved foods.

With no document for the restaurant, Coach estimates from its own knowledge with `create`. With a document
but no matching row, Coach says so and asks for the name as printed on the menu before offering an estimate.

## Reading and indexing

PDFKit extracts text locally, reconstructing visual table rows. Pages without sufficient embedded text use
local Vision OCR (English/Japanese). Documents are limited to 25 MB, 60 pages and 30,000 characters per
readable page. The PDF binary is not retained; the page text is, so a logged figure can always be checked
against the line it came from. Re-importing the same file (same SHA-256) replaces it.

The name index is the only AI use at import and is optional. When Coach is connected with data consent,
each page's text (lines numbered) plus the typed brand and market is sent to the configured provider once,
asking for each menu row's printed name and up to three aliases (an English name, a romanisation, a short
name). The reply carries no figures and none are read from it. An entry is kept only when its line exists,
prints a number, is not a header, and contains the name as printed. Without an index, or for a page whose
indexing failed, raw-line search still finds an item requested by the name as printed.

## Limits

The figure check stops invented or misremembered numbers, not swapped columns: if Coach puts the fat value
in carbohydrate and both are printed on the row, the check passes. The header shown on the card is how the
user catches that. Source evidence is a plausibility check, not proof of publisher authenticity.

## Provenance

The existing `macroSource` string carries a `nutrition-document:` JSON/base64 envelope: document filename,
SHA-256, page, the header and row as evidence, supplied brand/market, whether fibre was listed and whether
the user adjusted values. A rough-portion flag can coexist in the envelope. Food rows and meal snapshots
already preserve this field through backups. The stored documents travel inside the SQLite file, so the
`.noopbak` settings whitelist is unaffected. Deleting a document keeps everything logged or saved from it.

Foods saved by the earlier eager import keep working unchanged: they are ordinary library foods with a
document citation, and Coach prefers them via `log`.
