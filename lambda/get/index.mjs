import {
  DynamoDBClient,
  QueryCommand,
  GetItemCommand
} from "@aws-sdk/client-dynamodb";

const ddb = new DynamoDBClient({});
const H = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "*",
  "access-control-allow-methods": "GET,PUT,OPTIONS",
  "content-type": "application/json"
};
const ok  = (b)=>({statusCode:200,headers:H,body:JSON.stringify(b)});
const bad = (c,m)=>({statusCode:c,headers:H,body:JSON.stringify({message:m})});

const js = (s,def=[])=>{ try { return JSON.parse(s||"null") ?? def; } catch { return def; } };
const pick = (arr,n)=>{ const a=[...arr]; for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1)); [a[i],a[j]]=[a[j],a[i]];} return a.slice(0,Math.max(0,Math.min(n,a.length))); };

export const handler = async (event) => {
  try {
    const TableName = process.env.TABLE;
    const qp = event.queryStringParameters || {};
    const quizId = qp.quizId || null;
    const admin  = qp.admin === "1" || qp.admin === "true";
    const count  = qp.count ? Math.max(1, parseInt(qp.count,10)||0) : null;

    if (!quizId) {
      // List quizzes via GSI1 (GSI1PK = 'QUIZ')
      const q = await ddb.send(new QueryCommand({
        TableName,
        IndexName: "GSI1",
        KeyConditionExpression: "GSI1PK = :p",
        ExpressionAttributeValues: { ":p": { S: "QUIZ" } }
      }));
      const items = (q.Items||[]).map(it => ({
        quizId: it.quizId?.S || it.PK.S.replace("QUIZ#",""),
        title:  it.title?.S  || it.quizId?.S || "Untitled"
      }));
      return ok(items);
    }

    // Meta (optional)
    const meta = await ddb.send(new GetItemCommand({
      TableName,
      Key: { PK:{S:`QUIZ#${quizId}`}, SK:{S:"METADATA"} }
    }));
    const title = meta.Item?.title?.S || quizId;

    // All questions
    const qr = await ddb.send(new QueryCommand({
      TableName,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :sk)",
      ExpressionAttributeValues: {
        ":pk": { S: `QUIZ#${quizId}` },
        ":sk": { S: "QUESTION#" }
      }
    }));
    const full = (qr.Items||[]).map(it => ({
      qId: it.SK.S.substring("QUESTION#".length),
      prompt: it.prompt?.S || "",
      choices: js(it.choices?.S, []),
      correct: js(it.correct?.S, []),
      explanation: it.explanation?.S || ""
    }));

    const questions = (count && !admin) ? pick(full, count) : full;
    return ok({ quizId, title, questions });
  } catch (e) {
    console.error(e);
    return bad(500, "Internal Server Error");
  }
};
