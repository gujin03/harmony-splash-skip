import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

/** PoC 阶段主界面只做「开启引导」静态说明，不调用任何待核实接口 */
export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Log.error(`loadContent failed code=${err.code} msg=${err.message}`);
        return;
      }
      Log.info('loadContent ok');
    });
  }
}
