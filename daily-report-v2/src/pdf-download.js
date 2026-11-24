import {buildReportPdf} from './pdf.js';
let cachedFont;
async function loadFont(){if(!cachedFont)cachedFont=fetch(`${import.meta.env.BASE_URL}fonts/NanumGothic-Regular.ttf`).then(async response=>{if(!response.ok)throw Error('PDF 글꼴을 불러오지 못했습니다. 다시 시도해 주세요.');const bytes=new Uint8Array(await response.arrayBuffer());let binary='';for(let offset=0;offset<bytes.length;offset+=32768)binary+=String.fromCharCode(...bytes.subarray(offset,offset+32768));return btoa(binary);}).catch(error=>{cachedFont=null;throw error;});return cachedFont;}
export async function downloadReportPdf(report,attachments){const font=await loadFont();const doc=buildReportPdf(report,attachments,font);const name=`${report.report_date}_${report.author_name}_일일업무보고.pdf`.replace(/[\\/:*?"<>|]/g,'_');doc.save(name);}
