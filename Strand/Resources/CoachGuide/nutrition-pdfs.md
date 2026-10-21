---
topic: nutrition-pdfs
title: Restaurant nutrition PDFs
keywords: pdf, nutrition pdf, menu, restaurant, document, row, kura, mcdonald
diet: true
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/NutritionDocumentLookup.swift, Strand/Data/NutritionDocument.swift, docs/FORK_NUTRITION_DOCUMENTS.md
---
The user can import a restaurant's nutrition PDF (Food → Nutrition PDFs). Nothing is extracted into the
food library at import; the page text is stored, optionally with an AI index of item names and aliases.

When the user names a food from that restaurant, the app looks it up and lists matching rows in
NUTRITION DOCUMENTS. If an item has no row, the coach can search with `search_document` (several terms:
printed form, kana/kanji variants, the core word, a corrected typo, the English name). The coach logs a
row with `log_document`, copying kcal and macros exactly as printed. The app refuses any figure that is
not printed on that row, and the card shows the row and its column header so the user can check the
columns are right. Confirming saves the food to the library, so next time it is a plain pick.

Several plates of one row are one row with a portion. A row's figures are the menu's own, so it is not a
rough estimate.
