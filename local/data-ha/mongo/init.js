// Run by docker compose exec against localhost on mongo-a, not by a remote client.
const admin = db.getSiblingDB('admin');
const user = process.env.MONGO_ADMIN_USERNAME;
const password = process.env.MONGO_ADMIN_PASSWORD;
function worked(result) {
  if (!result || !result.ok) throw new Error(JSON.stringify(result));
  return result;
}
try { admin.auth(user, password); } catch (error) { if (error.code !== 18) throw error; }
let status;
try { status = rs.status(); }
catch (error) {
  if (error.code !== 94) throw error;
  worked(rs.initiate({_id:'doktori-rs', members:[{_id:0,host:'mongo-a:27017'}]}));
}
if (status && status.members.length === 3) {
  const hosts = rs.conf().members.map(member => member.host).sort();
  if (JSON.stringify(hosts) !== JSON.stringify(['mongo-a:27017','mongo-b:27017','mongo-c:27017'])) {
    throw new Error('Existing member addresses differ; manual review required');
  }
  print('Existing complete replica set retained; no primary forcing or reconfiguration');
  quit(0);
}
for (let n=0; n<60 && !db.hello().isWritablePrimary; n++) sleep(1000);
if (!db.hello().isWritablePrimary) throw new Error('No primary on bootstrap coordinator');
let authenticated = false;
try { authenticated = admin.auth(user,password); } catch (error) { if (error.code !== 18) throw error; }
if (!authenticated) {
  worked(admin.runCommand({createUser:user,pwd:password,
    roles:[{role:'root',db:'admin'}],writeConcern:{w:1}}));
  admin.auth(user,password);
}
const config = rs.conf();
const expected = ['mongo-a:27017','mongo-b:27017','mongo-c:27017'];
if (config.members.some(member => !expected.includes(member.host))) throw new Error('Unexpected existing members; manual review required');
for (const [id,host] of expected.entries()) {
  if (!rs.conf().members.some(member => member.host === host)) worked(rs.add({_id:id,host:host}));
}
print('Replica set configured; remote probe will verify all data members and create app/monitor users');
