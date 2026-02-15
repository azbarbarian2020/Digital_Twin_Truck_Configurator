import { NextResponse } from "next/server";
import { query, getFullTableName } from "@/lib/snowflake";

interface SelectedOption {
  optionId: string;
  optionName: string;
  componentGroup: string;
  specs: Record<string, number> | null;
}

interface ValidationIssue {
  type: string;
  title: string;
  message: string;
  relatedOptions: string[];
  sourceDoc?: string;
  specMismatches?: Array<{ specName: string; currentValue: number | null; requiredValue: number | null; reason: string }>;
}

interface FixPlan {
  remove: string[];
  add: string[];
  explanation: string;
}

export async function POST(request: Request) {
  console.log("\n=== VALIDATION API CALLED ===");
  try {
    const { selectedOptions, modelId } = await request.json();
    
    console.log(`Validating ${selectedOptions?.length || 0} options for model ${modelId}`);
    
    if (!selectedOptions || !Array.isArray(selectedOptions) || selectedOptions.length === 0) {
      return NextResponse.json({ issues: [], suggestions: [], fixPlan: { remove: [], add: [], explanation: "" } });
    }
    
    // Get full details for selected options
    const optionDetails = await getOptionDetails(selectedOptions);
    const optionsByGroup = new Map<string, SelectedOption>();
    for (const opt of optionDetails) {
      optionsByGroup.set(opt.componentGroup, opt);
    }
    
    // Find all validation rules for docs linked to ANY of the selected options
    const quotedIds = selectedOptions.map((id: string) => `'${id.replace(/'/g, "''")}'`).join(",");
    
    const rules = await query<{
      RULE_ID: string;
      DOC_ID: string;
      DOC_TITLE: string;
      LINKED_OPTION_ID: string;
      COMPONENT_GROUP: string;
      SPEC_NAME: string;
      MIN_VALUE: number | null;
      MAX_VALUE: number | null;
      UNIT: string;
      RAW_REQUIREMENT: string;
    }>(`
      SELECT RULE_ID, DOC_ID, DOC_TITLE, LINKED_OPTION_ID, COMPONENT_GROUP, 
             SPEC_NAME, MIN_VALUE, MAX_VALUE, UNIT, RAW_REQUIREMENT
      FROM ${getFullTableName('VALIDATION_RULES')}
      WHERE LINKED_OPTION_ID IN (${quotedIds})
    `);
    
    console.log(`Found ${rules.length} validation rules for selected options`);
    
    if (rules.length === 0) {
      console.log("No validation rules apply - configuration valid");
      return NextResponse.json({ 
        issues: [], 
        suggestions: [], 
        fixPlan: { remove: [], add: [], explanation: "" } 
      });
    }
    
    const issues: ValidationIssue[] = [];
    const toRemove: string[] = [];
    const toAdd: string[] = [];
    const explanations: string[] = [];
    
    // Group rules by component group
    const rulesByComponentGroup = new Map<string, typeof rules>();
    for (const rule of rules) {
      if (!rulesByComponentGroup.has(rule.COMPONENT_GROUP)) {
        rulesByComponentGroup.set(rule.COMPONENT_GROUP, []);
      }
      rulesByComponentGroup.get(rule.COMPONENT_GROUP)!.push(rule);
    }
    
    // Check each component group with rules
    for (const [componentGroup, groupRules] of rulesByComponentGroup) {
      const currentPart = optionsByGroup.get(componentGroup);
      
      if (!currentPart) {
        console.log(`No part selected for ${componentGroup} - skipping`);
        continue;
      }
      
      console.log(`Checking ${currentPart.optionName} against ${groupRules.length} rules for ${componentGroup}`);
      
      const specMismatches: Array<{ specName: string; currentValue: number | null; requiredValue: number | null; reason: string }> = [];
      const sourceDoc = groupRules[0].DOC_TITLE;
      const linkedOptionId = groupRules[0].LINKED_OPTION_ID;
      
      // Get linked option name for better messaging
      const linkedOption = optionDetails.find(o => o.optionId === linkedOptionId);
      const linkedOptionName = linkedOption?.optionName || linkedOptionId;
      
      for (const rule of groupRules) {
        const currentValue = currentPart.specs?.[rule.SPEC_NAME] ?? null;
        
        if (rule.MIN_VALUE !== null && currentValue !== null) {
          if (currentValue < rule.MIN_VALUE) {
            console.log(`  ✗ ${rule.SPEC_NAME}=${currentValue} < ${rule.MIN_VALUE} ✗`);
            specMismatches.push({
              specName: rule.SPEC_NAME,
              currentValue,
              requiredValue: rule.MIN_VALUE,
              reason: `has ${currentValue.toLocaleString()} ${rule.UNIT} but needs ${rule.MIN_VALUE.toLocaleString()} ${rule.UNIT}`
            });
          } else {
            console.log(`  ✓ ${rule.SPEC_NAME}=${currentValue.toLocaleString()} >= ${rule.MIN_VALUE.toLocaleString()} ✓`);
          }
        }
      }
      
      if (specMismatches.length > 0) {
        const issueMessages = specMismatches.map(m => m.reason).join('; ');
        
        issues.push({
          type: "error",
          title: `${currentPart.optionName} Incompatible`,
          message: `Per ${linkedOptionName} spec: ${issueMessages}`,
          relatedOptions: [currentPart.optionId, linkedOptionId],
          sourceDoc,
          specMismatches
        });
        
        // Find cheapest replacement
        const replacement = await findCheapestCompliantPart(groupRules, componentGroup, modelId);
        
        if (replacement) {
          toRemove.push(currentPart.optionId);
          toAdd.push(replacement.optionId);
          explanations.push(`Replace ${currentPart.optionName} with ${replacement.optionName} ($${replacement.cost.toLocaleString()})`);
        }
      }
    }
    
    return NextResponse.json({ 
      issues, 
      suggestions: [],
      fixPlan: {
        remove: [...new Set(toRemove)],
        add: [...new Set(toAdd)],
        explanation: explanations.length > 0
          ? `Per engineering specifications:\n• ${explanations.join('\n• ')}`
          : ""
      }
    });
  } catch (error) {
    console.error("Error validating:", error);
    return NextResponse.json({ issues: [], suggestions: [], fixPlan: { remove: [], add: [], explanation: "" } });
  }
}

async function getOptionDetails(optionIds: string[]): Promise<SelectedOption[]> {
  const quotedIds = optionIds.map(id => `'${id.replace(/'/g, "''")}'`).join(",");
  
  const results = await query<{
    OPTION_ID: string;
    OPTION_NM: string;
    COMPONENT_GROUP: string;
    SPECS: string | null;
  }>(`
    SELECT OPTION_ID, OPTION_NM, COMPONENT_GROUP, SPECS::VARCHAR as SPECS
    FROM ${getFullTableName('BOM_TBL')}
    WHERE OPTION_ID IN (${quotedIds})
  `);
  
  return results.map(r => ({
    optionId: r.OPTION_ID,
    optionName: r.OPTION_NM,
    componentGroup: r.COMPONENT_GROUP,
    specs: r.SPECS ? JSON.parse(r.SPECS) : null
  }));
}

interface ReplacementPart {
  optionId: string;
  optionName: string;
  cost: number;
}

async function findCheapestCompliantPart(
  rules: Array<{ SPEC_NAME: string; MIN_VALUE: number | null; COMPONENT_GROUP: string }>,
  componentGroup: string,
  modelId?: string
): Promise<ReplacementPart | null> {
  const candidatesQuery = modelId ? `
    SELECT b.OPTION_ID, b.OPTION_NM, b.SPECS::VARCHAR as SPECS, b.COST_USD
    FROM ${getFullTableName('BOM_TBL')} b
    JOIN ${getFullTableName('TRUCK_OPTIONS')} t ON b.OPTION_ID = t.OPTION_ID
    WHERE b.COMPONENT_GROUP = '${componentGroup.replace(/'/g, "''")}'
      AND t.MODEL_ID = '${modelId}'
    ORDER BY b.COST_USD ASC
  ` : `
    SELECT OPTION_ID, OPTION_NM, SPECS::VARCHAR as SPECS, COST_USD
    FROM ${getFullTableName('BOM_TBL')}
    WHERE COMPONENT_GROUP = '${componentGroup.replace(/'/g, "''")}'
    ORDER BY COST_USD ASC
  `;
  
  console.log(`  Finding cheapest ${componentGroup} meeting ${rules.length} requirements...`);
  
  try {
    const candidates = await query<{
      OPTION_ID: string;
      OPTION_NM: string;
      SPECS: string;
      COST_USD: number;
    }>(candidatesQuery);
    
    if (candidates.length === 0) return null;
    
    console.log(`  Evaluating ${candidates.length} candidates...`);
    
    for (const candidate of candidates) {
      const specs = candidate.SPECS ? JSON.parse(candidate.SPECS) : {};
      let meetsAll = true;
      
      for (const rule of rules) {
        if (rule.MIN_VALUE === null) continue;
        const value = specs[rule.SPEC_NAME] ?? 0;
        if (value < rule.MIN_VALUE) {
          meetsAll = false;
          break;
        }
      }
      
      if (meetsAll) {
        console.log(`  ✓ CHEAPEST: ${candidate.OPTION_NM} ($${candidate.COST_USD.toLocaleString()})`);
        return {
          optionId: candidate.OPTION_ID,
          optionName: candidate.OPTION_NM,
          cost: candidate.COST_USD
        };
      }
    }
    
    return null;
  } catch (error) {
    console.error("Failed to find replacement:", error);
    return null;
  }
}
