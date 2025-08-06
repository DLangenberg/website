import {
  DynamoDBClient,
  QueryCommand,
  PutItemCommand,
  BatchWriteItemCommand
} from "@aws-sdk/client-dynamodb";

const ddb = new DynamoDBClient({});
const H = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "*",
  "access-control-allow-methods": "GET,PUT,OPTIONS"
};
const noContent = ()=>({statusCode:204,headers:H});
const bad = (c,m)=>({statusCode:c,headers:{...H,"content-type":"application/json"},body:JSON.stringify({message:m})});

export const handler = async (event) => {
  try {
    const TableName = process.env.TABLE;
    let b={}; try { b = JSON.parse(event.body||"{}"); } catch { return bad(400,"Invalid JSON"); }

    const quizId = String(b.quizId||"").trim();
    if (!quizId) return bad(400,"quizId required");
    const title = String(b.title||quizId).trim();

    const arr = Array.isArray(b.questions) ? b.questions : null;
    if (!arr) return bad(400,"questions[] required");

    // 1) Upsert metadata (also maintain listing GSI)
    await ddb.send(new PutItemCommand({
      TableName,
      Item: {
        PK:{S:`QUIZ#${quizId}`},
        SK:{S:"METADATA"},
        quizId:{S:quizId},
        title:{S:title},
        GSI1PK:{S:"QUIZ"},
        GSI1SK:{S:`${title.toLowerCase()}#${quizId}`}
      }
    }));

    // 2) Load current questions to detect deletions
    const current = await ddb.send(new QueryCommand({
      TableName,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :sk)",
      ExpressionAttributeValues: {
        ":pk": { S: `QUIZ#${quizId}` },
        ":sk": { S: "QUESTION#" }
      }
    }));
    const existingKeys = new Set((current.Items||[]).map(it => it.SK.S)); // "QUESTION#nnn"

    // 3) Prepare full snapshot puts
    const puts = arr.map((q, idx) => {
      const qId = String(q.qId ?? (idx+1)).padStart(3,"0");
      existingKeys.delete(`QUESTION#${qId}`);
      return {
        PutRequest: {
          Item: {
            PK:{S:`QUIZ#${quizId}`},
            SK:{S:`QUESTION#${qId}`},
            prompt:{S:String(q.prompt||"")},
            choices:{S:JSON.stringify(q.choices||[])},
            correct:{S:JSON.stringify(q.correct||[])},
            explanation:{S:String(q.explanation||"")}
          }
        }
      };
    });

    // 4) Deletions for any remaining existingKeys
    const dels = [...existingKeys].map(sk => ({
      DeleteRequest: {
        Key: { PK:{S:`QUIZ#${quizId}`}, SK:{S:sk} }
      }
    }));

    // 5) Batch write in chunks of 25
    const batch = async (items) => {
      for (let i=0; i<items.length; i+=25) {
        const slice = items.slice(i, i+25);
        await ddb.send(new BatchWriteItemCommand({ RequestItems: { [TableName]: slice } }));
      }
    };

    await batch(puts);
    if (dels.length) await batch(dels);

    return noContent();
  } catch (e) {
    console.error(e);
    return bad(500,"Internal Server Error");
  }
};
