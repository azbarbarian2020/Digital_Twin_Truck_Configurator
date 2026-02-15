import { NextResponse } from "next/server";
import { query, getFullTableName, getSchema, getDatabase, putFile } from "@/lib/snowflake";
import { writeFile, unlink } from "fs/promises";
import { join } from "path";
import { tmpdir } from "os";

function getStageRef(): string {
  return `@${getDatabase()}.${getSchema()}.ENGINEERING_DOCS_STAGE`;
}

export async function POST(request: Request): Promise<Response> {
  let tempFilePath: string | null = null;
  
  const encoder = new TextEncoder();
  const stream = new TransformStream();
  const writer = stream.writable.getWriter();
  
  const sendProgress = async (step: string, status: 'pending' | 'active' | 'done' | 'error', message?: string) => {
    const data = JSON.stringify({ step, status, message });
    await writer.write(encoder.encode(`data: ${data}\n\n`));
  };
  
  const sendResult = async (result: object) => {
    await writer.write(encoder.encode(`data: ${JSON.stringify({ type: 'result', ...result })}\n\n`));
    await writer.close();
  };

  (async () => {
    try {
      const formData = await request.formData();
      const file = formData.get("file") as File | null;
      
      // Support both targetOptionId (direct) and linkedParts (JSON array from frontend)
      let targetOptionId = formData.get("targetOptionId") as string | null;
      const linkedPartsInput = formData.get("linkedParts") as string | null;
      if (!targetOptionId && linkedPartsInput) {
        try {
          const linkedParts = JSON.parse(linkedPartsInput);
          if (Array.isArray(linkedParts) && linkedParts.length > 0 && linkedParts[0].optionId) {
            targetOptionId = linkedParts[0].optionId;
            console.log(`Extracted targetOptionId from linkedParts: ${targetOptionId}`);
          }
        } catch (e) {
          console.log("Could not parse linkedParts:", linkedPartsInput);
        }
      }
      
      if (!file) {
        await sendResult({ success: false, error: "No file provided" });
        return;
      }
      
      if (!file.name.toLowerCase().endsWith(".pdf")) {
        await sendResult({ success: false, error: "Only PDF files are supported" });
        return;
      }

      await sendProgress('upload', 'active', 'Uploading to Snowflake stage...');
      
      const bytes = await file.arrayBuffer();
      const buffer = Buffer.from(bytes);
      
      const sanitizedName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_");
      const stageFileName = sanitizedName;
      tempFilePath = join(tmpdir(), stageFileName);
      await writeFile(tempFilePath, buffer);
      
      try {
        await putFile(tempFilePath, getStageRef());
      } catch (uploadError) {
        console.error("Stage upload failed:", uploadError);
        await sendProgress('upload', 'error', 'Failed to upload to stage');
        await sendResult({ success: false, error: "Failed to upload file to Snowflake stage" });
        return;
      }
      
      await sendProgress('upload', 'done');
      await sendProgress('extract', 'active', 'Extracting text with PARSE_DOCUMENT...');

      const extractResult = await query<{ FULL_TEXT: string }>(`
        SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
          '${getStageRef()}',
          '${stageFileName}',
          {'mode': 'LAYOUT'}
        ):content::VARCHAR AS FULL_TEXT
      `);
      
      if (!extractResult.length || !extractResult[0].FULL_TEXT) {
        await sendProgress('extract', 'error', 'Failed to extract text');
        await sendResult({ success: false, error: "Failed to extract text from PDF" });
        return;
      }
      
      const fullText = extractResult[0].FULL_TEXT;
      await sendProgress('extract', 'done');
      
      await sendProgress('chunk', 'active', 'Creating searchable chunks...');
      
      const docTitle = extractDocTitle(fullText, sanitizedName);
      const docId = `DOC-${Date.now()}-${Math.random().toString(36).substr(2, 6)}`.toUpperCase();
      
      let linkedPartsJson: string | null = null;
      let linkedOptionId: string | null = targetOptionId;
      if (targetOptionId) {
        const optionInfo = await query<{ OPTION_NM: string; COMPONENT_GROUP: string }>(`
          SELECT OPTION_NM, COMPONENT_GROUP 
          FROM ${getFullTableName('BOM_TBL')} 
          WHERE OPTION_ID = '${targetOptionId}'
        `);
        if (optionInfo.length > 0) {
          linkedPartsJson = JSON.stringify([{
            optionId: targetOptionId,
            optionName: optionInfo[0].OPTION_NM,
            componentGroup: optionInfo[0].COMPONENT_GROUP
          }]);
        }
      }
      
      const chunks = chunkText(fullText, 1500, 200);
      
      for (let i = 0; i < chunks.length; i++) {
        const chunkTextContent = chunks[i].replace(/'/g, "''");
        const linkedPartsExpr = linkedPartsJson ? `PARSE_JSON('${linkedPartsJson.replace(/'/g, "''")}')` : 'NULL';
        await query(`
          INSERT INTO ${getFullTableName('ENGINEERING_DOCS_CHUNKED')}
            (DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX, CHUNK_TEXT, LINKED_PARTS)
          SELECT 
            '${docId}', '${docTitle.replace(/'/g, "''")}', 
            '${getStageRef()}/${stageFileName}', 
            ${i + 1}, '${chunkTextContent}', ${linkedPartsExpr}
        `);
      }
      
      await sendProgress('chunk', 'done', `Created ${chunks.length} chunks`);
      
      await sendProgress('search', 'active', 'Refreshing search service...');
      
      try {
        await query(`ALTER CORTEX SEARCH SERVICE ${getDatabase()}.${getSchema()}.ENGINEERING_DOCS_SEARCH REFRESH`);
        await sendProgress('search', 'done');
      } catch (refreshError) {
        console.warn("Search refresh warning:", refreshError);
        await sendProgress('search', 'done', 'Auto-refresh scheduled');
      }
      
      // Use Cortex Search to find requirement sections, then extract rules
      await sendProgress('rules', 'active', 'Searching for component requirements...');
      const rulesCreated = await extractRulesWithSearch(docId, docTitle, linkedOptionId);
      await sendProgress('rules', 'done', `Created ${rulesCreated} validation rules`);
      
      await sendResult({
        success: true,
        docId,
        docTitle,
        chunkCount: chunks.length,
        rulesCreated
      });
      
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      const errorStack = error instanceof Error ? error.stack : undefined;
      console.error("Upload error:", errorMessage);
      console.error("Stack:", errorStack);
      await sendResult({ 
        success: false,
        error: errorMessage,
        details: errorStack
      });
    } finally {
      if (tempFilePath) {
        try {
          await unlink(tempFilePath);
        } catch {}
      }
    }
  })();

  return new Response(stream.readable, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    },
  });
}

async function extractRulesWithSearch(docId: string, docTitle: string, linkedOptionId: string | null): Promise<number> {
  const db = getDatabase();
  const schema = getSchema();
  
  // Use Cortex Search to find requirement-related chunks in THIS document
  const searchQueries = [
    'minimum boost pressure PSI turbocharger requirements',
    'cooling capacity BTU radiator requirements',
    'torque rating transmission requirements',
    'braking horsepower engine brake requirements',
    'component specifications minimum requirements'
  ];
  
  const relevantChunks: string[] = [];
  
  for (const searchQuery of searchQueries) {
    try {
      // SEARCH_PREVIEW takes 2 args: service_name, search_request (JSON with query + options)
      const searchRequest = JSON.stringify({
        query: searchQuery,
        columns: ["CHUNK_TEXT", "DOC_ID"],
        filter: {"@eq": {"DOC_ID": docId}},
        limit: 3
      }).replace(/'/g, "''");
      
      const searchResult = await query<{ RESULTS: string }>(`
        SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
          '${db}.${schema}.ENGINEERING_DOCS_SEARCH',
          '${searchRequest}'
        )::VARCHAR as RESULTS
      `);
      
      if (searchResult.length > 0 && searchResult[0].RESULTS) {
        const parsed = JSON.parse(searchResult[0].RESULTS);
        const results = parsed.results || [];
        for (const r of results) {
          if (r.CHUNK_TEXT && !relevantChunks.includes(r.CHUNK_TEXT)) {
            relevantChunks.push(r.CHUNK_TEXT);
          }
        }
      }
    } catch (searchErr) {
      console.log(`Search query failed: ${searchQuery}`, searchErr);
    }
  }
  
  if (relevantChunks.length === 0) {
    console.log(`No requirement chunks found for ${docTitle}`);
    return 0;
  }
  
  console.log(`Found ${relevantChunks.length} relevant chunks via Cortex Search`);
  
  // Now use Cortex Complete to extract structured rules from the search results
  const combinedText = relevantChunks.join('\n\n---\n\n').substring(0, 6000);
  
  const prompt = `Extract component requirements from these engineering specification sections.

DOCUMENT: ${docTitle}

RELEVANT SECTIONS:
${combinedText}

Extract numeric requirements for supporting components. Valid component groups and their spec names:
- Turbocharger: boost_psi, max_hp_supported
- Radiator: cooling_capacity_btu, core_rows
- Transmission Type: torque_rating_lb_ft
- Engine Brake Type: braking_hp, brake_stages
- Frame Rails: yield_strength_psi, rbm_rating_in_lb
- Axle Rating: gawr_lb, beam_thickness_in
- Front Suspension Type: spring_rating_lb
- Rear Suspension Type: spring_rating_lb

For each requirement mentioned, return JSON with the EXACT componentGroup name from above.

Return JSON array:
[
  {"componentGroup": "Turbocharger", "specName": "boost_psi", "minValue": 45, "unit": "PSI", "rawRequirement": "minimum 45 PSI boost"},
  {"componentGroup": "Frame Rails", "specName": "yield_strength_psi", "minValue": 80000, "unit": "PSI", "rawRequirement": "80,000 PSI yield strength"}
]

Return [] if no numeric requirements found. Return ONLY the JSON array.`;

  try {
    console.log('Calling Cortex Complete for rule extraction...');
    console.log('Prompt length:', prompt.length);
    
    const aiResult = await query<{ RESPONSE: string }>(`
      SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', '${prompt.replace(/'/g, "''")}') AS RESPONSE
    `);
    
    console.log('Cortex Complete returned:', aiResult.length, 'rows');
    
    if (!aiResult.length) {
      console.log('No AI result returned');
      return 0;
    }
    
    let response = aiResult[0].RESPONSE.trim();
    console.log('AI response for rule extraction:', response.substring(0, 500));
    
    // Strip markdown code blocks if present
    response = response.replace(/```json\s*/gi, '').replace(/```\s*/g, '');
    
    const jsonMatch = response.match(/\[[\s\S]*\]/);
    if (!jsonMatch) {
      console.log('No JSON array found in AI response');
      return 0;
    }
    
    console.log('Matched JSON:', jsonMatch[0].substring(0, 300));
    
    const rules = JSON.parse(jsonMatch[0]) as Array<{
      componentGroup: string;
      specName: string;
      minValue: number;
      maxValue?: number;
      unit: string;
      rawRequirement: string;
    }>;
    
    // Insert rules into VALIDATION_RULES table
    for (const rule of rules) {
      const escapedRaw = (rule.rawRequirement || '').replace(/'/g, "''");
      await query(`
        INSERT INTO ${getFullTableName('VALIDATION_RULES')} 
          (DOC_ID, DOC_TITLE, LINKED_OPTION_ID, COMPONENT_GROUP, SPEC_NAME, MIN_VALUE, MAX_VALUE, UNIT, RAW_REQUIREMENT)
        VALUES (
          '${docId}',
          '${docTitle.replace(/'/g, "''")}',
          ${linkedOptionId ? `'${linkedOptionId}'` : 'NULL'},
          '${rule.componentGroup.replace(/'/g, "''")}',
          '${rule.specName.replace(/'/g, "''")}',
          ${rule.minValue || 'NULL'},
          ${rule.maxValue || 'NULL'},
          '${(rule.unit || '').replace(/'/g, "''")}',
          '${escapedRaw}'
        )
      `);
    }
    
    console.log(`Created ${rules.length} validation rules for ${docTitle}`);
    return rules.length;
    
  } catch (err) {
    console.error('Failed to extract rules:', err instanceof Error ? err.message : err);
    console.error('Stack:', err instanceof Error ? err.stack : 'N/A');
    return 0;
  }
}

function extractDocTitle(text: string, filename: string): string {
  const lines = text.split('\n').filter(l => l.trim());
  
  for (const line of lines.slice(0, 10)) {
    const clean = line.replace(/[#*_]/g, '').trim();
    if (clean.length > 10 && clean.length < 100) {
      if (/specification|requirement|compatibility|engineering|application/i.test(clean)) {
        return clean;
      }
    }
  }
  
  return filename.replace(/\.pdf$/i, '').replace(/_/g, ' ');
}

function chunkText(text: string, chunkSize: number, overlap: number): string[] {
  const chunks: string[] = [];
  const paragraphs = text.split(/\n\s*\n/);
  
  let currentChunk = "";
  
  for (const para of paragraphs) {
    const trimmed = para.trim();
    if (!trimmed) continue;
    
    if (currentChunk.length + trimmed.length > chunkSize && currentChunk.length > 0) {
      chunks.push(currentChunk.trim());
      const words = currentChunk.split(' ');
      const overlapWords = words.slice(-Math.floor(overlap / 5));
      currentChunk = overlapWords.join(' ') + '\n\n' + trimmed;
    } else {
      currentChunk += (currentChunk ? '\n\n' : '') + trimmed;
    }
  }
  
  if (currentChunk.trim()) {
    chunks.push(currentChunk.trim());
  }
  
  return chunks.length > 0 ? chunks : [text.substring(0, chunkSize)];
}
