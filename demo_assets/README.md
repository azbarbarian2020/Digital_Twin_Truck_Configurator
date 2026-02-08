# Demo Assets

This folder contains sample engineering specification documents for demonstrating the **Validate Configuration** feature.

## Primary Demo Document

### 605_HP_Engine_Requirements.pdf

This document contains engineering specifications for the 605 HP Maximum Power engine upgrade, including:
- Cooling system requirements
- Transmission compatibility
- Turbocharger specifications
- Engine brake requirements

## Demo Walkthrough

### Step 1: Access the Application
Open the Digital Twin Truck Configurator at your deployed URL.

### Step 2: Select a Compatible Truck Model
Choose one of these models (they have the 605 HP engine option):
- **Heavy Haul Max HH-1200**
- **Executive Hauler EX-1500**

### Step 3: Upload the Specification Document
1. Click the **"Engineering Docs"** tab
2. Click **"Upload Document"**
3. Select `605_HP_Engine_Requirements.pdf` from this folder
4. Wait for processing (uses PARSE_DOCUMENT to extract text)

### Step 4: Link to Component (Optional)
The system auto-detects that this document applies to the "605 HP / 2050 lb-ft Maximum" engine option. You can verify or manually adjust the linked components.

### Step 5: Validate Your Configuration
1. Configure your truck with various options
2. Click **"Verify Configuration"**
3. The system will:
   - Extract requirements from the PDF (cooling capacity, transmission specs, etc.)
   - Compare against your selected components' specifications
   - Show pass/fail for each requirement
   - Recommend alternative components if requirements aren't met

### Example Validation Results

If you select the 605 HP engine but choose an incompatible cooling package, you'll see:

```
✗ Cooling Capacity: 350,000 BTU required, your selection provides 280,000 BTU
  → Recommendation: Upgrade to "Extreme Duty Cooling" ($4,500)

✓ Transmission Torque Rating: 1,850 lb-ft required, your selection provides 2,200 lb-ft

✓ Turbocharger Boost: 45 PSI required, your selection provides 48 PSI
```

## Additional Sample Documents

More engineering specification documents are available in `docker/public/docs/`:
- `ENG-605-MAX-Technical-Specification.pdf`
- `Heavy_Duty_Cooling_Package_Requirements.pdf`
- `20000_lb_Heavy_Duty_Front_Axle_Compatibility_v2.pdf`

## Configuration Assistant Questions

After uploading documents, try these questions in the Configuration Assistant:

1. "What are the cooling requirements for the 605 HP engine?"
2. "Is my current transmission compatible with the maximum power engine?"
3. "What turbocharger do I need for the heavy haul configuration?"
4. "Which components need to be upgraded for the 605 HP option?"

The assistant uses Cortex Search (RAG) to find relevant information from your uploaded documents.
