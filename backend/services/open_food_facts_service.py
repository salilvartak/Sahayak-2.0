from __future__ import annotations

from typing import Any
import httpx


class OpenFoodFactsService:
    BASE_URL = "https://world.openfoodfacts.org/api/v0/product"

    async def fetch_product(self, barcode: str) -> dict[str, Any] | None:
        code = (barcode or "").strip()
        if not code:
            return None

        url = f"{self.BASE_URL}/{code}.json"
        try:
            async with httpx.AsyncClient(timeout=8.0) as client:
                resp = await client.get(url)
            if resp.status_code != 200:
                return None
            data = resp.json()
            if int(data.get("status", 0)) != 1:
                return None
            return data.get("product") or None
        except Exception:
            return None

    def build_prompt_context(self, barcode: str, product: dict[str, Any] | None) -> str:
        if not product:
            return (
                "## Barcode Product Lookup\n"
                f"- Barcode: {barcode}\n"
                "- Product data source: Open Food Facts\n"
                "- Result: No product found for this barcode.\n"
            )

        name = (
            product.get("product_name_en")
            or product.get("product_name")
            or product.get("generic_name_en")
            or product.get("generic_name")
            or "Unknown product"
        )
        brand = product.get("brands") or "Unknown"
        quantity = product.get("quantity") or "Unknown"
        categories = product.get("categories") or "Unknown"
        ingredients = product.get("ingredients_text_en") or product.get("ingredients_text") or "Unknown"
        nutriscore = product.get("nutriscore_grade") or "Unknown"
        countries = product.get("countries") or "Unknown"

        nutriments = product.get("nutriments") or {}
        energy = nutriments.get("energy-kcal_100g") or nutriments.get("energy-kcal")
        sugars = nutriments.get("sugars_100g")
        salt = nutriments.get("salt_100g")
        fat = nutriments.get("fat_100g")

        nutrition_line = (
            f"Energy(kcal): {energy if energy is not None else 'Unknown'}, "
            f"Sugars/100g: {sugars if sugars is not None else 'Unknown'}, "
            f"Salt/100g: {salt if salt is not None else 'Unknown'}, "
            f"Fat/100g: {fat if fat is not None else 'Unknown'}"
        )

        return (
            "## Barcode Product Lookup\n"
            f"- Barcode: {barcode}\n"
            "- Product data source: Open Food Facts\n"
            f"- Name: {name}\n"
            f"- Brand: {brand}\n"
            f"- Quantity: {quantity}\n"
            f"- Categories: {categories}\n"
            f"- Countries: {countries}\n"
            f"- Nutri-Score: {nutriscore}\n"
            f"- Nutrition: {nutrition_line}\n"
            f"- Ingredients: {ingredients}\n"
        )


open_food_facts_service = OpenFoodFactsService()
