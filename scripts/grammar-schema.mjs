// @ts-check

/** @typedef {null | boolean | number | string | SchemaValue[] | { [key: string]: SchemaValue }} SchemaValue */

const UNSUPPORTED_KEYWORDS = new Set(["pattern", "$schema", "additionalProperties"]);
const SCHEMA_MAP_KEYWORDS = new Set(["properties", "patternProperties", "$defs", "dependentSchemas"]);
const SCHEMA_KEYWORDS = new Set([
  "items", "prefixItems", "contains", "allOf", "anyOf", "oneOf", "not",
  "if", "then", "else", "propertyNames", "unevaluatedProperties", "unevaluatedItems", "contentSchema"
]);

/**
 * @param {SchemaValue} schema
 * @param {(schema: { [key: string]: SchemaValue }) => { [key: string]: SchemaValue }} normalizeObject
 * @returns {SchemaValue}
 */
export function sanitizeGrammarSchema(schema, normalizeObject = (value) => value) {
  if (schema === null || typeof schema !== "object") return schema;
  if (Array.isArray(schema)) {
    return schema.map((value) => sanitizeGrammarSchema(value, normalizeObject));
  }

  const sanitized = Object.fromEntries(
    Object.entries(schema)
      .filter(([key]) => !UNSUPPORTED_KEYWORDS.has(key))
      .map(([key, value]) => {
        if (SCHEMA_MAP_KEYWORDS.has(key)) {
          const schemas = /** @type {{ [key: string]: SchemaValue }} */ (value);
          return [key, Object.fromEntries(Object.entries(schemas).map(([name, child]) =>
            [name, sanitizeGrammarSchema(child, normalizeObject)]))];
        }
        return [key, SCHEMA_KEYWORDS.has(key) ? sanitizeGrammarSchema(value, normalizeObject) : value];
      })
  );
  return normalizeObject(sanitized);
}
