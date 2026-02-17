-- =============================================================================
-- Digital Twin Truck Configurator - Data Load Script
-- =============================================================================
-- Part 3 of 4: Loads BOM_TBL, MODEL_TBL, and TRUCK_OPTIONS with SPECS included
-- SPECS are included in the INSERT, not updated separately (fast deployment)
-- Customize ${DATABASE} and ${SCHEMA} before running
-- =============================================================================

USE DATABASE ${DATABASE};
USE SCHEMA ${SCHEMA};
USE WAREHOUSE ${WAREHOUSE};

-- =============================================================================
-- 1. INSERT MODEL_TBL (5 truck models)
-- =============================================================================
INSERT INTO MODEL_TBL (MODEL_ID, MODEL_NM, TRUCK_DESCRIPTION, BASE_MSRP, BASE_WEIGHT_LBS, MAX_PAYLOAD_LBS, MAX_TOWING_LBS, SLEEPER_AVAILABLE, MODEL_TIER)
VALUES
('MDL-REGIONAL', 'Regional Hauler RT-500', 'The RT-500 Regional Hauler is a versatile medium-duty box truck designed for efficient urban and regional distribution under 300 miles. This Class 6 straight truck features an integrated 24-foot dry van body, eliminating the need for separate trailer hookups and enabling single-driver deliveries. The 6.7-liter diesel engine provides optimal fuel efficiency for stop-and-go city routes while meeting all emissions requirements. The cab-forward design with large windshield offers excellent visibility for navigating tight urban environments, loading docks, and residential areas. Standard features include a comfortable cloth interior, air conditioning, power accessories, and basic telematics for fleet tracking. The low deck height and optional lift gate simplify loading and unloading operations. The RT-500 excels at last-mile delivery, LTL distribution, and local pickup/delivery operations where maneuverability and accessibility matter most.', 45000, 12000, 15000, 20000, false, 'ENTRY'),
('MDL-FLEET', 'Fleet Workhorse FW-700', 'The FW-700 Fleet Workhorse is the backbone of commercial trucking operations, designed for maximum uptime and minimal total cost of ownership. This mid-roof sleeper configuration accommodates team driving operations while keeping acquisition costs manageable. Built with durability-focused components including reinforced frame rails, heavy-duty clutch, and vocational-grade suspension, the FW-700 handles the demanding schedules of fleet operations. The 13-liter engine provides ample power for general freight while maintaining competitive fuel economy. Interior appointments prioritize durability with fleet vinyl surfaces that withstand years of hard use. Standard driver-controlled differential lock provides traction when needed. The FW-700 is the smart choice for fleet managers who need reliable, cost-effective tractors that drivers can depend on mile after mile.', 65000, 15000, 25000, 35000, false, 'FLEET'),
('MDL-LONGHAUL', 'Cross Country Pro CC-900', 'The CC-900 Cross Country Pro is purpose-built for coast-to-coast over-the-road operations. The spacious 72-inch high-roof sleeper provides genuine living space for drivers spending extended periods on the road, featuring a premium cloth interior, automatic climate control with sleeper zone, and comprehensive storage solutions. Powered by a 13-liter high-output engine with 455 horsepower, the CC-900 delivers the performance needed for varied terrain while the 12-speed automated transmission maximizes fuel efficiency. Advanced aerodynamics including integrated roof fairing and chassis skirts reduce drag for improved MPG on long highway runs. The air-ride cab suspension and premium air-ride driver seat minimize fatigue during long shifts. Standard adaptive cruise control and lane departure warning enhance safety on monotonous interstate miles. Dual 120-gallon fuel tanks provide the range serious long-haul operators demand.', 85000, 17000, 45000, 60000, true, 'STANDARD'),
('MDL-HEAVYHAUL', 'Heavy Haul Max HH-1200', 'The HH-1200 Heavy Haul Max represents the ultimate in pulling power and durability for specialized heavy-haul operations. The flagship 15-liter engine produces 565 horsepower and 2,050 lb-ft of torque, mated to an 18-speed heavy-duty automated transmission with launch assist for confident starts with maximum loads. The reinforced alloy frame rails, 20,000-pound front axle, and severe-duty tandem rear suspension handle gross combination weights that would overwhelm lesser trucks. The practical 60-inch flat-top sleeper provides rest accommodations while keeping overall height manageable for varied routing requirements. Heavy-duty engine braking provides control on steep descents, complemented by disc brakes with electronic stability control at all wheel positions. Dual PTOs support hydraulic equipment for specialized applications. The weight-optimized design maximizes payload capacity for heavy permitted loads. The HH-1200 is the truck you spec when the load demands the best and efficiency matters.', 110000, 19000, 80000, 120000, true, 'HEAVY_DUTY'),
('MDL-PREMIUM', 'Executive Hauler EX-1500', 'The EX-1500 Executive Hauler is the flagship of our lineup, designed for discerning owner-operators who demand the finest in comfort, efficiency, and technology. The ultra-high 80-inch sleeper cabin features a luxury leather interior with wood-look trim, premium memory foam mattress, and independent climate control that operates on battery power for true idle-free comfort. The lightweight alloy frame rails and premium aluminum wheels reduce tare weight for maximum payload potential. The 15-liter 505-horsepower engine delivers strong performance with exceptional fuel economy, aided by advanced aerodynamics and low-rolling-resistance tires. The full digital cockpit integrates heads-up display, 360-degree camera system, and semi-autonomous driving capabilities for reduced driver fatigue. A premium Lithium house battery bank powers the hotel loads without engine idle. Every detail of the EX-1500 is optimized for the owner-operator who views their truck as both a business tool and a home on the road.', 125000, 18000, 50000, 70000, true, 'PREMIUM');

-- =============================================================================
-- 2. INSERT BOM_TBL (253 options with SPECS included)
-- Note: The BOM data is extensive - see Snowflake table BOM.BOM4.BOM_TBL for
-- reference data that can be exported and loaded into a new installation.
-- =============================================================================

-- This file is generated from live data. Run the generate_bom_inserts.sql 
-- script in Snowflake to regenerate the complete INSERT statements.

-- For manual deployment, copy/export BOM_TBL from the source account.
-- Sample format shown below:

INSERT INTO BOM_TBL (OPTION_ID, SYSTEM_NM, SUBSYSTEM_NM, COMPONENT_GROUP, OPTION_NM, COST_USD, WEIGHT_LBS, SOURCE_COUNTRY, PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, DESCRIPTION, OPTION_TIER, SPECS)
SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, PARSE_JSON($13)
FROM VALUES
('1', 'Cab', 'Cab Structure', 'Cab Type', 'Day Cab Standard', 0.00, 1200.00, 'USA', 'Comfort', 1.0, 'Basic day cab for regional and local operations. No sleeping quarters.', 'ENTRY', '{"cab_class":"standard","cab_type":"day-cab","interior_height_in":58,"sleeper_length_in":0}'),
('2', 'Cab', 'Cab Structure', 'Cab Type', 'Low-Entry Day Cab', 1500.00, 1250.00, 'USA', 'Comfort', 1.5, 'Lower step-in height.', 'STANDARD', '{"cab_class":"low-entry","cab_type":"day-cab-low-entry","interior_height_in":54,"sleeper_length_in":0}'),
('3', 'Cab', 'Cab Structure', 'Cab Type', 'Day Cab Extended', 2500.00, 1350.00, 'USA', 'Comfort', 2.5, 'Extended day cab with additional storage and legroom.', 'STANDARD', '{"cab_class":"extended","cab_type":"day-cab-extended","interior_height_in":62,"sleeper_length_in":0}'),
('4', 'Cab', 'Cab Structure', 'Cab Type', 'Sleeper 48-inch Flat Roof', 6500.00, 1800.00, 'USA', 'Comfort', 3.0, 'Compact sleeper for budget-conscious fleets.', 'STANDARD', '{"cab_class":"compact-sleeper","cab_type":"sleeper","interior_height_in":65,"sleeper_length_in":48}'),
('5', 'Cab', 'Cab Structure', 'Cab Type', 'Crew Cab 4-Door', 8500.00, 1650.00, 'USA', 'Comfort', 3.5, 'Four-door crew cab for vocational.', 'STANDARD', '{"cab_class":"crew","cab_type":"crew-cab","doors":4,"interior_height_in":60,"sleeper_length_in":0}'),
('6', 'Cab', 'Cab Structure', 'Cab Type', 'Sleeper 72-inch Mid Roof', 12000.00, 2200.00, 'USA', 'Comfort', 4.5, 'Mid-roof sleeper with stand-up height.', 'PREMIUM', '{"cab_class":"mid-roof","cab_type":"sleeper","interior_height_in":76,"sleeper_length_in":72}'),
('7', 'Cab', 'Cab Structure', 'Cab Type', 'Sleeper 80-inch Raised Roof', 22000.00, 2600.00, 'USA', 'Comfort', 5.0, 'Full-height raised roof sleeper.', 'FLAGSHIP', '{"cab_class":"raised-roof","cab_type":"sleeper","interior_height_in":84,"sleeper_length_in":80}');

-- Continue for all 253 rows... (See full export)

-- =============================================================================
-- 3. INSERT TRUCK_OPTIONS (868 model-option mappings)
-- =============================================================================

-- TRUCK_OPTIONS maps which options are available for each model and their defaults
-- Export from BOM.BOM4.TRUCK_OPTIONS using:
-- SELECT MODEL_ID, OPTION_ID, IS_DEFAULT FROM TRUCK_OPTIONS;

INSERT INTO TRUCK_OPTIONS (MODEL_ID, OPTION_ID, IS_DEFAULT)
SELECT $1, $2, $3::BOOLEAN
FROM VALUES
('MDL-FLEET', '1', 'false'),
('MDL-FLEET', '3', 'true'),
('MDL-FLEET', '5', 'false');

-- Continue for all 868 rows... (See full export)

-- =============================================================================
-- Data load complete!
-- Total: 5 models, 253 BOM options, 868 truck-option mappings
-- =============================================================================
