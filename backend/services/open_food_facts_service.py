from __future__ import annotations

import time
from typing import Any
import httpx


# Simple in-memory cache: barcode → (timestamp, product_dict)
_CACHE: dict[str, tuple[float, dict | None]] = {}
_CACHE_TTL = 3600  # 1 hour


class OpenFoodFactsService:
    BASE_URL = "https://world.openfoodfacts.org/api/v0/product"

    def __init__(self):
        # Persistent client — reuses TCP connections across requests
        self._http = httpx.AsyncClient(
            timeout=8.0,
            headers={"User-Agent": "Sahayak-App/1.0 (contact@sahayak.app)"},
        )

    async def fetch_product(self, barcode: str) -> dict[str, Any] | None:
        code = (barcode or "").strip()
        if not code:
            return None

        # Cache hit
        if code in _CACHE:
            ts, cached = _CACHE[code]
            if time.time() - ts < _CACHE_TTL:
                return cached

        url = f"{self.BASE_URL}/{code}.json"
        try:
            resp = await self._http.get(url)
            if resp.status_code != 200:
                _CACHE[code] = (time.time(), None)
                return None
            data = resp.json()
            if int(data.get("status", 0)) != 1:
                _CACHE[code] = (time.time(), None)
                return None
            product = data.get("product") or None
            _CACHE[code] = (time.time(), product)
            return product
        except Exception:
            return None

    def build_prompt_context(self, barcode: str, product: dict[str, Any] | None) -> str:
        """
        Returns a concise, structured product context block for the LLM system prompt.
        Returns empty string when product is not found so the LLM falls back to image reading.
        """
        if not product:
            return ""  # Silent fallback — LLM reads label from image instead

        # ── Name & brand ──────────────────────────────────────────────────────
        name = (
            product.get("product_name_en")
            or product.get("product_name")
            or product.get("generic_name_en")
            or product.get("generic_name")
            or ""
        )
        brand    = product.get("brands", "")
        quantity = product.get("quantity", "")

        # ── Ingredients ───────────────────────────────────────────────────────
        ingredients = (
            product.get("ingredients_text_en")
            or product.get("ingredients_text")
            or ""
        )

        # ── Allergens ─────────────────────────────────────────────────────────
        allergens_raw = (
            product.get("allergens_from_ingredients")
            or product.get("allergens")
            or ""
        )
        # Strip "en:" prefixes: "en:milk,en:nuts" → "milk, nuts"
        allergens = ", ".join(
            a.strip().split(":")[-1]
            for a in allergens_raw.split(",")
            if a.strip()
        ) if allergens_raw else ""

        # ── Labels (organic, vegan, halal, …) ────────────────────────────────
        labels_raw = product.get("labels", "") or ""
        labels = ", ".join(
            lbl.strip().split(":")[-1].replace("-", " ")
            for lbl in labels_raw.split(",")
            if lbl.strip()
        ) if labels_raw else ""

        # ── Nutrition ─────────────────────────────────────────────────────────
        nutriments = product.get("nutriments") or {}
        energy  = nutriments.get("energy-kcal_100g") or nutriments.get("energy-kcal")
        sugars  = nutriments.get("sugars_100g")
        fat     = nutriments.get("fat_100g")
        sat_fat = nutriments.get("saturated-fat_100g")
        salt    = nutriments.get("salt_100g")
        protein = nutriments.get("proteins_100g")
        fiber   = nutriments.get("fiber_100g")

        nutrition_parts = []
        if energy  is not None: nutrition_parts.append(f"Energy {energy} kcal")
        if protein is not None: nutrition_parts.append(f"Protein {protein}g")
        if fat     is not None: nutrition_parts.append(f"Fat {fat}g")
        if sat_fat is not None: nutrition_parts.append(f"Sat. fat {sat_fat}g")
        if sugars  is not None: nutrition_parts.append(f"Sugars {sugars}g")
        if salt    is not None: nutrition_parts.append(f"Salt {salt}g")
        if fiber   is not None: nutrition_parts.append(f"Fiber {fiber}g")
        nutrition_line = " | ".join(nutrition_parts) if nutrition_parts else ""

        # ── Nutri-Score ───────────────────────────────────────────────────────
        nutriscore = (product.get("nutriscore_grade") or "").upper()
        nutriscore_desc = {
            "A": "A (very healthy)",
            "B": "B (healthy)",
            "C": "C (moderate)",
            "D": "D (poor)",
            "E": "E (very poor — high fat/sugar/salt)",
        }.get(nutriscore, "")

        # ── Additives ─────────────────────────────────────────────────────────
        additives_list = product.get("additives_tags") or []
        # Keep only E-number codes, strip "en:" prefix
        additives = ", ".join(
            a.split(":")[-1].upper()
            for a in additives_list[:8]   # cap at 8 to keep context small
            if a
        ) if additives_list else ""

        # ── Assemble context block ────────────────────────────────────────────
        lines = ["## Verified Product Data (from barcode scan)"]
        if name:        lines.append(f"- Product: {name}")
        if brand:       lines.append(f"- Brand: {brand}")
        if quantity:    lines.append(f"- Quantity: {quantity}")
        if nutriscore_desc: lines.append(f"- Nutri-Score: {nutriscore_desc}")
        if nutrition_line:  lines.append(f"- Nutrition (per 100g): {nutrition_line}")
        if allergens:   lines.append(f"- Allergens: {allergens}")
        if labels:      lines.append(f"- Labels/Certifications: {labels}")
        if additives:   lines.append(f"- Additives: {additives}")
        if ingredients: lines.append(f"- Ingredients: {ingredients[:400]}")  # cap length

        return "\n".join(lines)


open_food_facts_service = OpenFoodFactsService()
