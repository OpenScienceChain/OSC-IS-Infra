INSERT INTO "organization_entity"
  ("id", "name", "description", "slug", "mspId", "ledgerGroupName", "ledgerApiUserId", "artifactSchemaName", "status")
VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'NEUROSCIENCE GATEWAY', 'Local NSG evidence organization', 'neuroscience-gateway', 'NSGMSP', 'nsg', 'nsg-service', 'research-artifact', 'active'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'CITIZEN SCIENCE', 'Local Citizen Science evidence organization', 'citizen-science', 'CitizenScienceMSP', 'citizen-science', 'citizen-service', 'research-artifact', 'active')
ON CONFLICT ("id") DO UPDATE SET
  "name" = EXCLUDED."name", "slug" = EXCLUDED."slug", "mspId" = EXCLUDED."mspId", "status" = 'active';

INSERT INTO "user_entity"
  ("id", "name", "username", "email", "password", "roles", "platformAdmin", "authVersion", "organizationId")
VALUES
  ('10000000-0000-4000-8000-000000000001', 'NSG Administrator', 'nsg-admin', 'nsg-admin@example.invalid', :'password_hash', 'admin', false, 0, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('10000000-0000-4000-8000-000000000002', 'NSG Principal Investigator', 'nsg-pi', 'nsg-pi@example.invalid', :'password_hash', 'pi', false, 0, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('10000000-0000-4000-8000-000000000003', 'NSG Collaborator', 'nsg-collaborator', 'nsg-collaborator@example.invalid', :'password_hash', 'collaborator', false, 0, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('10000000-0000-4000-8000-000000000004', 'Citizen Science Administrator', 'citizen-admin', 'citizen-admin@example.invalid', :'password_hash', 'admin', false, 0, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  ('10000000-0000-4000-8000-000000000005', 'Citizen Science Contributor', 'citizen-contributor', 'citizen-contributor@example.invalid', :'password_hash', 'collaborator', false, 0, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  ('10000000-0000-4000-8000-000000000006', 'Cross Organization Researcher', 'cross-org', 'cross-org@example.invalid', :'password_hash', 'collaborator', false, 0, NULL)
ON CONFLICT ("username") DO UPDATE SET "password" = EXCLUDED."password", "authVersion" = 0;

INSERT INTO "organization_membership"
  ("id", "roles", "status", "userId", "organizationId")
VALUES
  ('20000000-0000-4000-8000-000000000001', 'admin', 'active', '10000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('20000000-0000-4000-8000-000000000002', 'pi', 'active', '10000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('20000000-0000-4000-8000-000000000003', 'collaborator', 'active', '10000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('20000000-0000-4000-8000-000000000004', 'admin', 'active', '10000000-0000-4000-8000-000000000004', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  ('20000000-0000-4000-8000-000000000005', 'collaborator', 'active', '10000000-0000-4000-8000-000000000005', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  ('20000000-0000-4000-8000-000000000006', 'collaborator', 'active', '10000000-0000-4000-8000-000000000006', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('20000000-0000-4000-8000-000000000007', 'collaborator', 'active', '10000000-0000-4000-8000-000000000006', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
ON CONFLICT ("userId", "organizationId") DO UPDATE SET "roles" = EXCLUDED."roles", "status" = 'active';
