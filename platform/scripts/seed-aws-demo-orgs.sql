INSERT INTO "organization_entity"
  ("id", "name", "description", "slug", "mspId", "ledgerGroupName", "ledgerApiUserId", "artifactSchemaName", "status")
VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Neuroscience Gateway', 'OSC demo organization for neuroscience provenance records.', 'neuroscience-gateway', 'NSGMSP', 'nsg', 'nsg-service', 'research-artifact', 'active'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Citizen Science', 'OSC demo organization for citizen-science provenance records.', 'citizen-science', 'CitizenScienceMSP', 'citizen-science', 'citizen-service', 'research-artifact', 'active')
ON CONFLICT ("id") DO NOTHING;
