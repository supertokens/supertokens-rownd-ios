import { cpSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const destination = process.argv[2];
if (!destination) throw new Error('Usage: node test-server/create-released-consumer.mjs <new destination>');
mkdirSync(destination, { recursive: false });
cpSync(path.join(root, 'example'), path.join(destination, 'example'), { recursive: true });
const project = path.join(destination, 'example/landmarks.xcodeproj/project.pbxproj');
let contents = readFileSync(project, 'utf8');
contents = contents.replaceAll('XCLocalSwiftPackageReference', 'XCRemoteSwiftPackageReference');
contents = contents.replace('relativePath = ..;', `repositoryURL = "https://github.com/supertokens/supertokens-rownd-ios";
            requirement = { kind = exactVersion; version = 0.2.8; };`);
// Pin the transitive dependency as well: Rownd's released manifest uses a range.
contents = contents.replace('packageReferences = (', 'packageReferences = (\n                DRAFT05400000000000000001,');
contents = contents.replace('/* End XCRemoteSwiftPackageReference section */', `
        DRAFT05400000000000000001 = {
            isa = XCRemoteSwiftPackageReference;
            repositoryURL = "https://github.com/supertokens/supertokens-ios";
            requirement = { kind = exactVersion; version = 0.5.4; };
        };
/* End XCRemoteSwiftPackageReference section */`);
if (contents.includes('isa = XCLocalSwiftPackageReference')) throw new Error('Local package override remains');
writeFileSync(project, contents);
console.log(`Released consumer: ${project}`);
