# Nutrition document import (Apple fork)

Food → Import nutrition PDF imports a user-selected nutrition document into the personal food library.
The user supplies the restaurant/brand and market/country because similarly named products can have
different serving sizes and formulations across markets. There is no built-in restaurant database,
automatic web lookup, publisher authentication, subscription, hosted service or new account.

PDFKit extracts text locally, reconstructing visual table rows. Pages without sufficient embedded text
use local Vision OCR (English/Japanese). Documents are limited to 25 MB, 60 pages and 30,000 characters
per readable page. The source PDF is not uploaded or retained by NOOP. Reading is cancellable and runs
off the UI actor.

Extraction is an explicit export: **Extract with AI** sends each readable page's text plus brand/market
metadata to the existing configured provider. It requires Coach configuration and its existing data
consent. It does not send chat history, health data or the PDF binary. The extraction persona treats
document contents as untrusted data and requests only explicitly printed nutrition rows. This is a
user-requested extension of the fork's existing optional AI export boundary, not a dependency of strap
sync or ordinary food logging.

The parser requires kcal, protein, carbohydrate and fat, an explicit serving basis, and a source quote
containing the numbers and item name. Missing required nutrients are not silently zero-filled. Missing
fibre is labelled as unlisted in review; the existing macro model stores zero for unavailable fibre.
Source evidence is a plausibility check, not proof of column assignment or authenticity. **User review
is mandatory**, and selected values/servings can be corrected before saving. No meal is logged by an
import. A failed extraction or cancellation saves nothing. The completed catalog saves in one database
transaction; re-importing matching document foods preserves food IDs. Unrelated manual foods and past
meal snapshots are not overwritten.

The existing `macroSource` string carries a `nutrition-document:` JSON/base64 provenance envelope:
document filename, SHA-256, source page/quote, supplied brand/market, whether fibre was listed and
whether the user adjusted values. A rough-portion flag can coexist in the envelope, preserving both
source attribution and the existing daily intake-uncertainty calculation. Existing food rows and meal snapshots already preserve this field,
including through backups; no migration or backup whitelist change is needed. The original PDF is not
part of the backup. Editing a document food marks it user-adjusted. AI macro edits retain the existing
AI-estimate provenance instead of continuing to claim document values.

Coach ranks the saved library against recent conversation text before building its bounded food
context, includes document citations, and is instructed to prefer matching source foods and ask about
ambiguous markets/sizes. A `log` action resolves to the saved food ID and stored macros, including when
the model emits a different prose estimate. The confirmation card displays the source citation.

Validation covers local PDF reading, unsupported/missing extraction values, serving/provenance
round-trips, idempotent catalog persistence, authoritative Coach logging and relevant-food retrieval
beyond the normal 60-entry context limit. A live provider extraction and on-device OCR review remain
manual checks; no paid API request is required by the tests.
