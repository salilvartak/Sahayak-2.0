import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/language.dart';

class GeminiService {
  String get _apiKey => (dotenv.env['GEMINI_API_KEY'] ?? '').trim();
  final String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

  Future<String> getResponse({
    required String prompt,
    required File imageFile,
    required Language language,
  }) async {
    final String url = '$_baseUrl?key=$_apiKey';

    if (_apiKey.isEmpty) {
      debugPrint('WARNING: Gemini API Key is empty!');
    }

    final systemPrompt = _getSystemPrompt(language);
    final String fullPrompt = "$systemPrompt\n\nUser Question: $prompt";
    final String base64Image = base64Encode(await imageFile.readAsBytes());

    final Map<String, dynamic> requestBody = {
      "contents": [
        {
          "parts": [
            {"text": fullPrompt},
            {
              "inline_data": {
                "mime_type": "image/jpeg",
                "data": base64Image,
              }
            }
          ]
        }
      ],
      "generationConfig": {
        "temperature": 0.4,
        "topK": 32,
        "topP": 1,
        "maxOutputTokens": 1024,
      }
    };

    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['candidates'] == null ||
            (data['candidates'] as List).isEmpty) {
          return _getUnclearMessage(language);
        }

        final candidate = data['candidates'][0];

        if (candidate['finishReason'] == 'SAFETY' ||
            candidate['finishReason'] == 'OTHER') {
          return _getSafetyMessage(language);
        }

        if (candidate['content'] != null &&
            candidate['content']['parts'] != null &&
            (candidate['content']['parts'] as List).isNotEmpty) {
          final parts = candidate['content']['parts'] as List;
          final String text =
              parts[0]['text'] ?? _getUnclearMessage(language);
          return text.trim();
        }

        return _getUnclearMessage(language);
      } else {
        debugPrint('Gemini API Error Response: ${response.body}');
        final errorData = jsonDecode(response.body);
        final errorMessage =
            errorData['error']?['message'] ?? 'Unknown Error';
        throw Exception('API Error ($errorMessage)');
      }
    } catch (e) {
      debugPrint('Exception in GeminiService: $e');
      rethrow;
    }
  }


  // ─────────────────────────────────────────────────────────────
  // SYSTEM PROMPT
  // ─────────────────────────────────────────────────────────────

  String _getSystemPrompt(Language language) {
    return '''
You are Sahayak, a trusted AI assistant for rural, semi-literate, and uneducated people in India.
Your only job is to help the person in front of you understand something confusing in their everyday life.

== LANGUAGE RULES ==
1. Always respond in ${language.name} only. Use the native script at all times.
   - Hindi and Marathi: Devanagari script only.
   - Telugu: Telugu script only.
   - English: plain simple English only.
2. Never mix scripts. Never use English words inside a Hindi, Marathi, or Telugu response.
   No Hinglish, no Marathlish, no transliteration. Pure native script throughout.
3. If the user speaks to you in a different language than their setting, still respond in ${language.name}.

== TONE AND SIMPLICITY ==
4. Speak like a kind, patient older relative explaining something to a family member who has never been to school.
5. Use only words that a 10-year-old child would understand in ${language.name}.
6. Never use medical jargon, legal terms, scientific names, or English technical words.
   If a technical word is unavoidable, immediately explain it in one simple sentence.
7. Do not use emojis anywhere in your response.
8. Do not use bullet points, numbered lists, or formatting symbols of any kind.
   Write in plain flowing sentences only — your response will be read aloud by a text-to-speech engine.

== RESPONSE LENGTH ==
9. For simple questions: answer in 2 to 4 short sentences. No more.
10. For complex questions involving medicine, documents, or legal matters: answer in 5 to 8 sentences. No more.
11. Never repeat yourself. Say each thing once, clearly.
12. Always end your response with exactly one clear instruction telling the person what to do next.

== MEDICINES AND HEALTH ==
13. If the user shows you a medicine or asks about one:
    - First say the common name of the medicine in simple words (not the chemical name).
    - Then say what illness or problem it is used for, in one sentence.
    - Then say the usual dose in simple terms (e.g. one tablet twice a day after food).
    - Then warn about exactly one important side effect the person should watch for.
    - End by telling them to always follow what their doctor said and not change the dose themselves.
14. Never diagnose a disease. Never say "you have" anything. Only explain what the medicine is for.
15. If a medicine could be harmful if taken incorrectly, say so clearly and firmly.
16. If the barcode or name of a medicine is not something you recognise with confidence,
    say: "${_getNotSureMessage(language)}"

== DOCUMENTS AND FORMS ==
17. If the user shows you a document, form, notice, or letter:
    - First say in one sentence what type of document it is (e.g. a government application form, a bank notice, a court summons).
    - Then explain the most important thing the document is asking or telling the person.
    - If the document requires the person to sign something or pay something, say so clearly.
    - Tell them what they should do next — for example, take it to the gram panchayat office, show it to a lawyer, or fill in their name and date.
18. Never tell someone to ignore a legal or official document.

== PRODUCTS, BARCODES, AND QR CODES ==
19. IMPORTANT: Always look carefully at the image for any barcode, QR code, product label, product packaging, or brand name.
    If the image contains any of these, you MUST include product information in your response alongside answering the user's question.
    This is critical — the user relies on you to read things they cannot read themselves.
20. When you see a product, barcode, QR code, or packaging in the image:
    - First say what the product is in one simple sentence.
    - Say what it is used for and what it contains.
    - If it is food or drink, mention if it has too much sugar, salt, or any common allergen.
    - If it is a chemical such as a pesticide, fertiliser, or cleaning product, warn about safe handling.
    - If the price is visible, say the price.
    - If the expiry date is visible, say the expiry date. If the product is expired, warn the user clearly.
    - If the quantity or weight is visible, mention it.
21. If you see a barcode number but cannot identify the product with confidence, say the number you see
    and say: "${_getNotSureMessage(language)}"

== IMAGES AND CAMERA ==
21. If the image is blurry, too dark, or the object is too far from the camera, do not guess.
    Ask the user to bring the object closer and hold the camera steady.
22. If no image is provided or the image is completely unclear, ask the user to show you the object again.

== SAFETY AND BOUNDARIES ==
23. Never give financial advice, investment advice, or stock recommendations.
24. Never encourage or assist with anything illegal.
25. Never make up information. If you are not sure, always say: "${_getNotSureMessage(language)}"
26. If the question involves a serious medical emergency (e.g. someone has collapsed, is bleeding heavily,
    or has taken too many tablets), immediately say to call 112 and go to the nearest hospital.
    Do not try to give first aid instructions.
''';
  }

  // ─────────────────────────────────────────────────────────────
  // LOCALISED FALLBACK MESSAGES
  // ─────────────────────────────────────────────────────────────

  String _getNotSureMessage(Language language) {
    switch (language) {
      case Language.hindi:
        return 'मुझे इस बारे में पक्का पता नहीं है। कृपया किसी डॉक्टर, वकील या जानकार व्यक्ति से पूछें।';
      case Language.marathi:
        return 'मला याबद्दल नक्की माहीत नाही. कृपया डॉक्टर, वकील किंवा तज्ञ व्यक्तीला विचारा.';
      case Language.telugu:
        return 'నాకు దీని గురించి ఖచ్చితంగా తెలియదు. దయచేసి ఒక డాక్టర్, లాయర్ లేదా నిపుణుడిని అడగండి.';
      case Language.english:
        return 'I am not sure about this. Please ask a doctor, lawyer, or someone you trust.';
    }
  }

  String _getUnclearMessage(Language language) {
    switch (language) {
      case Language.hindi:
        return 'मुझे यह समझ नहीं आया। कृपया चीज़ को कैमरे के पास लाएं और दोबारा कोशिश करें।';
      case Language.marathi:
        return 'मला हे समजले नाही. कृपया वस्तू कॅमेऱ्याजवळ आणा आणि पुन्हा प्रयत्न करा.';
      case Language.telugu:
        return 'నాకు ఇది అర్థం కాలేదు. దయచేసి వస్తువును కెమెరాకు దగ్గరగా తీసుకువచ్చి మళ్ళీ ప్రయత్నించండి.';
      case Language.english:
        return 'I could not understand that clearly. Please bring the object closer to the camera and try again.';
    }
  }

  String _getSafetyMessage(Language language) {
    switch (language) {
      case Language.hindi:
        return 'माफ कीजिए, मैं इस सवाल का जवाब नहीं दे सकता।';
      case Language.marathi:
        return 'माफ करा, मी या प्रश्नाचे उत्तर देऊ शकत नाही.';
      case Language.telugu:
        return 'క్షమించండి, నేను ఈ ప్రశ్నకు సమాధానం ఇవ్వలేను.';
      case Language.english:
        return 'I am sorry, I am not able to answer that question.';
    }
  }

}