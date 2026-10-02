INSERT INTO "user_entity"
  ("id", "name", "username", "email", "password", "roles", "platformAdmin", "authVersion", "organizationId")
SELECT
  '30000000-0000-4000-8000-000000000003',
  'Magnetic Arch Evidence User',
  'magnetic-e2e',
  'magnetic-e2e@example.invalid',
  "password", 'collaborator', false, 0,
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
FROM "user_entity"
WHERE "username" = 'nsg-pi'
ON CONFLICT ("username") DO NOTHING;

INSERT INTO "organization_membership"
  ("id", "roles", "status", "userId", "organizationId")
VALUES
  ('30000000-0000-4000-8000-000000000013', 'collaborator', 'active',
   '30000000-0000-4000-8000-000000000003',
   'dddddddd-dddd-4ddd-8ddd-dddddddddddd')
ON CONFLICT ("userId", "organizationId") DO NOTHING;
